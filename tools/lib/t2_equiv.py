#!/usr/bin/env python3
"""Prove the T2-hybrid build plays every recorded session like the reference.

Usage: t2_equiv.py SESSIONS_DIR OUT_DIR A2EMU ROM DISK TITLE_PREFIX T2_BINARY START_PREFIX [JOBS]

SESSIONS_DIR is a Stage 4 coverage output (work/<slug>/coverage/sessions),
one folder per session with session.probe, session.keys and probe.out (the
boot replay). For each session:

  1. Count the keyboard polls the session's sites see before the first
     title-screen poll ($1E95) when booting with the real ROM.
  2. Shorten the first key's wait by that count, so a replay that starts at
     the title-screen snapshot presses every key at the same poll.
  3. Replay from the title snapshot in a2emu (real ROM) and from the
     ROM-free start image in the T2 binary, both without a ROM (how it ships)
     and with --rom= (the user's ROM refilling the blanked Monitor bytes).
  4. Require identical per-frame video hashes, identical probe output
     (keys, sites, disk sectors) and the same probe output as the boot replay
     once its pre-title disk reads are set aside. "end" lines are dropped: a
     probe `stop` ends the run at the end of the frame, so their count
     depends on where in the frame it fires.

Writes OUT_DIR/equivalence.json and equivalence.md; exits 1 if any session
differs.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

TITLE_POLL_SITE = "$1E95"
BOOT_FRAMES_TO_TITLE = 1000
MAX_SESSION_FRAMES = 400000
# A replay takes seconds; a T2 run that crashed runs to MAX_SESSION_FRAMES instead.
RUN_TIMEOUT_SECONDS = 120
FIRST_WAIT = re.compile(r"keyno == 0 && idle >= (\d+)")
POLL_INSTALL = re.compile(r"^install poll at (.+)$", re.M)


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(2)


def run(command: list[str], log: Path) -> None:
    with log.open("w") as out:
        try:
            result = subprocess.run(command, stdout=out, stderr=subprocess.STDOUT, timeout=RUN_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"{Path(command[0]).name} still running after {RUN_TIMEOUT_SECONDS}s "
                               f"(stuck or diverged); see {log}") from None
    if result.returncode != 0:
        raise RuntimeError(f"{Path(command[0]).name} exited {result.returncode}; see {log}")


def probe_lines(path: Path) -> list[str]:
    return [line for line in path.read_text().splitlines() if not line.startswith("end ")]


def matches_boot_replay(restored: list[str], boot: list[str]) -> bool:
    """The boot replay also logs the disk reads before the title screen
    (all before the first key); everything after them must be identical."""
    boot_only = len(boot) - len(restored)
    return (boot_only >= 0 and boot[boot_only:] == restored
            and all(line.startswith("sector key 0 ") for line in boot[:boot_only]))


class Equivalence:
    def __init__(self, args: list[str]) -> None:
        (sessions, out, self.a2emu, self.rom, self.disk, self.title,
         self.t2, self.start) = args[:8]
        self.sessions, self.out = Path(sessions), Path(out)
        self.jobs = int(args[8]) if len(args) > 8 else 4
        self.pre_title_polls: dict[str, int] = {}

    def count_pre_title_polls(self, sites: str, work: Path) -> int:
        """Polls at SITES before the first title-screen poll, booting with the ROM."""
        if sites in self.pre_title_polls:
            return self.pre_title_polls[sites]
        probe = work / "pre.probe"
        probe.write_text(
            "counter idle\ncounter done\nprobe poll(site = pc) {\n"
            f"  if (site == {TITLE_POLL_SITE} && done == 0) {{ printf(\"%u\\n\", idle)  done = 1  stop }}\n"
            "  inc idle\n}\n"
            f"install poll at {sites}\n")
        run([self.a2emu, f"--rom={self.rom}", f"--disk1={self.disk}", "--headless", "--no-sound",
             f"--frames={BOOT_FRAMES_TO_TITLE}", f"--probe={probe}", f"--probe-out={work / 'pre.out'}"],
            work / "pre.log")
        lines = (work / "pre.out").read_text().split()
        if not lines or not lines[0].isdigit():
            raise RuntimeError(f"no title-screen poll within {BOOT_FRAMES_TO_TITLE} frames; see {work}")
        self.pre_title_polls[sites] = int(lines[0])
        return self.pre_title_polls[sites]

    def replay_args(self, session: Path, work: Path, tag: str) -> list[str]:
        return [f"--disk1={self.disk}", "--headless", "--no-sound", f"--frames={MAX_SESSION_FRAMES}",
                f"--key-file={session / 'session.keys'}", f"--probe={work / 'restored.probe'}",
                f"--probe-out={work / (tag + '.out')}", f"--hash-frames={work / (tag + '.hash')}"]

    def check(self, session: Path) -> dict:
        name = session.name
        work = self.out / name
        work.mkdir(parents=True, exist_ok=True)
        result: dict = {"session": name, "equivalent": False}
        try:
            probe_text = (session / "session.probe").read_text()
            install = POLL_INSTALL.search(probe_text)
            waits = FIRST_WAIT.findall(probe_text)
            if install is None or len(waits) != 1:
                raise RuntimeError("session.probe has no single poll install line / first-key wait")
            pre_polls = self.count_pre_title_polls(install.group(1).strip(), work)
            first_wait = int(waits[0]) - pre_polls
            if first_wait <= 0:
                raise RuntimeError(f"first key due before the title screen ({waits[0]} <= {pre_polls})")
            (work / "restored.probe").write_text(
                FIRST_WAIT.sub(f"keyno == 0 && idle >= {first_wait}", probe_text))

            run([self.a2emu, f"--rom={self.rom}", f"--restore={self.title}",
                 *self.replay_args(session, work, "ref")], work / "ref.log")
            run([self.t2, f"--restore={self.start}", f"--t2-stats={work / 't2.stats.json'}",
                 *self.replay_args(session, work, "t2")], work / "t2.log")
            run([self.t2, f"--restore={self.start}", f"--rom={self.rom}",
                 *self.replay_args(session, work, "t2rom")], work / "t2rom.log")

            ref_hash, t2_hash = (work / "ref.hash").read_bytes(), (work / "t2.hash").read_bytes()
            t2rom_hash = (work / "t2rom.hash").read_bytes()
            ref_out, t2_out = probe_lines(work / "ref.out"), probe_lines(work / "t2.out")
            t2rom_out = probe_lines(work / "t2rom.out")
            stats = json.loads((work / "t2.stats.json").read_text())
            result.update({
                "pre_title_polls": pre_polls,
                "frames": ref_hash.count(b"\n"),
                "keys": sum(1 for line in ref_out if line.startswith("key ")),
                "restarts": stats["restarts"],
                "monitor_misses": stats["monitor_misses"],
                "native_percent": stats["native_percent"],
                "interpreted_uncompiled": stats["interpreted_uncompiled"],
                "interpreted_frame_split": stats["interpreted_frame_split"],
                "interpreted_changed_code": stats["interpreted_changed_code"],
                "top_uncompiled": stats["top_uncompiled"][:5],
            })
            if stats["restarts"] == 0:
                result.update({
                    "frames_equal": bool(ref_hash) and ref_hash == t2_hash,
                    "probe_equal": ref_out == t2_out,
                    "matches_boot_replay": matches_boot_replay(ref_out, probe_lines(session / "probe.out")),
                    "equal_with_user_rom": ref_hash == t2rom_hash and ref_out == t2rom_out,
                })
                result["equivalent"] = (result["frames_equal"] and result["probe_equal"]
                                        and result["matches_boot_replay"] and result["equal_with_user_rom"])
            else:
                total_keys = len((session / "session.keys").read_text().split("\n")) - 1
                result.update(self.restarted_checks(ref_hash, t2_hash, t2rom_hash, t2_out, t2rom_out,
                                                    stats, total_keys))
                result["equivalent"] = (result["frames_equal_before_restart"] and result["equal_with_user_rom"]
                                        and result["all_keys_after_restart"] and not stats["monitor_misses"])
        except (OSError, RuntimeError, ValueError, KeyError) as error:
            result["error"] = str(error)
        return result

    @staticmethod
    def restarted_checks(ref_hash: bytes, t2_hash: bytes, t2rom_hash: bytes, t2_out: list[str],
                         t2rom_out: list[str], stats: dict, total_keys: int) -> dict:
        """The game rebooted. The reference boots the disk again; T2 restarts at
        the title screen (it has no boot ROM), so the runs part there. Every
        frame that ended before the reboot must match, T2 must behave the same
        with and without the user's ROM, and play must go on to the last key."""
        restart_cycle = stats["first_restart_cycle"]

        def before_restart(hashes: bytes) -> list[bytes]:
            return [line for line in hashes.splitlines() if int(line.split()[1]) < restart_cycle]

        ref_before = before_restart(ref_hash)
        return {
            "restart_frame": len(ref_before),
            "frames_equal_before_restart": bool(ref_before) and ref_before == before_restart(t2_hash),
            "equal_with_user_rom": t2_hash == t2rom_hash and t2_out == t2rom_out,
            "all_keys_after_restart": sum(1 for line in t2_out if line.startswith("key ")) == total_keys,
        }

    def main(self) -> int:
        sessions = sorted(p for p in self.sessions.iterdir()
                          if p.is_dir() and (p / "session.probe").is_file())
        if not sessions:
            fail(f"{self.sessions}: no session folders with session.probe")
        self.out.mkdir(parents=True, exist_ok=True)
        # Sessions sharing a poll-site set share one boot count; fill the cache first.
        for session in sessions:
            install = POLL_INSTALL.search((session / "session.probe").read_text())
            if install:
                work = self.out / session.name
                work.mkdir(parents=True, exist_ok=True)
                self.count_pre_title_polls(install.group(1).strip(), work)
        with ThreadPoolExecutor(max_workers=self.jobs) as pool:
            results = list(pool.map(self.check, sessions))

        frames = sum(r.get("frames", 0) for r in results)
        total = {"sessions": len(results), "equivalent": sum(r["equivalent"] for r in results),
                 "frames": frames,
                 "uncompiled": sum(r.get("interpreted_uncompiled", 0) for r in results),
                 "min_native_percent": min((r.get("native_percent", 0.0) for r in results), default=0.0)}
        report = {"total": total, "sessions": results}
        (self.out / "equivalence.json").write_text(json.dumps(report, indent=2) + "\n")
        self.write_markdown(report)
        for r in results:
            state = "EQUAL" if r["equivalent"] else "DIFFERS"
            detail = r.get("error") or (f"{r['frames']} frames, {r['keys']} keys, "
                                        f"{r['native_percent']}% native, {r['interpreted_uncompiled']} uncompiled"
                                        + (f", game quit at frame {r['restart_frame']} and restarted"
                                           if r.get("restarts") else ""))
            print(f"  {state:8} {r['session']}: {detail}")
        print(f"{total['equivalent']}/{total['sessions']} sessions equivalent over {frames} frames; "
              f"{total['uncompiled']} uncompiled instructions; lowest native share {total['min_native_percent']}%")
        return 0 if total["equivalent"] == total["sessions"] else 1

    def write_markdown(self, report: dict) -> None:
        total = report["total"]
        lines = ["# T2-hybrid equivalence", "",
                 f"- **{total['equivalent']}/{total['sessions']}** sessions equivalent "
                 f"({total['frames']} frames compared)",
                 f"- Uncompiled instructions run by the interpreter: **{total['uncompiled']}**",
                 f"- Lowest native share: **{total['min_native_percent']}%**", "",
                 "| Session | Equivalent | Frames | Keys | Native % | Uncompiled | Frame split | Changed code | Quit + restart |",
                 "|---|---|---|---|---|---|---|---|---|"]
        for r in report["sessions"]:
            if "error" in r:
                lines.append(f"| {r['session']} | no: {r['error']} | | | | | | | |")
                continue
            lines.append(f"| {r['session']} | {'yes' if r['equivalent'] else 'no'} | {r['frames']} | "
                         f"{r['keys']} | {r['native_percent']} | {r['interpreted_uncompiled']} | "
                         f"{r['interpreted_frame_split']} | {r['interpreted_changed_code']} | "
                         f"{'frame ' + str(r['restart_frame']) if r.get('restarts') else '—'} |")
        (self.out / "equivalence.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    if len(sys.argv) < 9:
        fail(__doc__.split("\n\n")[1])
    sys.exit(Equivalence(sys.argv[1:]).main())
