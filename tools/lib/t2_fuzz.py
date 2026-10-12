#!/usr/bin/env python3
"""Make seeded random-key sessions that leave the recorded paths.

Usage: t2_fuzz.py OUT_DIR A2EMU ROM DISK POLL_SITES [SESSIONS] [KEYS]

POLL_SITES is a comma-separated hex list (the keyboard-read sites found by
the Stage 4/5 sessions). Each session answers the joystick question with N,
then presses KEYS random keys (moves, munch, menu keys, Esc, letters and
digits) at random poll intervals, so it wanders into menus, wrong answers,
Troggle deaths and screens no recorded session reached. Seeds are fixed, so
the sessions are the same on every run.

Writes OUT_DIR/fuzz-<seed>/session.probe, session.keys and probe.out (the
boot replay in a2emu with the real ROM), the same layout as a Stage 4
coverage session, so tools/lib/t2_equiv.py can compare T2 on them.
"""
from __future__ import annotations

import random
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from coverage_session import KEY_NAMES, write_probe  # noqa: E402

FIRST_WAIT = 60000
JOYSTICK_NO = ord("N")
MAX_FRAMES = 400000
RUN_TIMEOUT_SECONDS = 600
DEFAULT_SESSIONS = 8
DEFAULT_KEYS = 400
KEY_CHOICES = ([KEY_NAMES[k] for k in ("LEFT", "RIGHT", "UP", "DOWN")] * 6
               + [KEY_NAMES["SPACE"], KEY_NAMES["RETURN"]] * 4
               + [KEY_NAMES["ESC"], ord("Y"), ord("N"), ord("A"), ord("1"), ord("5")])
WAIT_CHOICES = [30, 30, 100, 300, 300, 1000, 3000]


def random_keys(seed: int, count: int) -> list[tuple[int, int]]:
    rng = random.Random(seed)
    return [(JOYSTICK_NO, FIRST_WAIT)] + [(rng.choice(KEY_CHOICES), rng.choice(WAIT_CHOICES))
                                          for _ in range(count)]


def main() -> int:
    if len(sys.argv) < 6:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    out, a2emu, rom, disk = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
    sites = {int(s, 16) for s in sys.argv[5].split(",") if s}
    sessions = int(sys.argv[6]) if len(sys.argv) > 6 else DEFAULT_SESSIONS
    key_count = int(sys.argv[7]) if len(sys.argv) > 7 else DEFAULT_KEYS
    for seed in range(1, sessions + 1):
        folder = out / f"fuzz-{seed}"
        folder.mkdir(parents=True, exist_ok=True)
        keys = random_keys(seed, key_count)
        write_probe(folder / "session.probe", keys, sites)
        (folder / "session.keys").write_text("".join(f"{i} {code}\n" for i, (code, _) in enumerate(keys, 1)))
        result = subprocess.run(
            [a2emu, f"--rom={rom}", f"--disk1={disk}", "--headless", "--no-sound", f"--frames={MAX_FRAMES}",
             f"--key-file={folder / 'session.keys'}", f"--probe={folder / 'session.probe'}",
             f"--probe-out={folder / 'probe.out'}"],
            capture_output=True, text=True, timeout=RUN_TIMEOUT_SECONDS)
        if result.returncode != 0:
            print(f"ERROR: boot replay of fuzz-{seed} exited {result.returncode}", file=sys.stderr)
            return 1
        delivered = sum(1 for line in (folder / "probe.out").read_text().splitlines() if line.startswith("key "))
        print(f"fuzz-{seed}: {delivered}/{len(keys)} keys delivered")
    return 0


if __name__ == "__main__":
    sys.exit(main())
