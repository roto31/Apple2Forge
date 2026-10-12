"""Run one Stage 4 coverage session headless and collect the code it executes.

Usage: python3 -I tools/lib/coverage_session.py SESSION_FILE OUT_DIR EMULATOR ROM DISK

A session file lists keys, one per line, each delivered once the game has
polled the keyboard WAIT times since the previous key ("key coordinates" in
the probe language, so replays do not depend on frame timing):

    # comment
    N 60000          key name or decimal code, optional WAIT (default 300)
    mark mode        name the next key, for expect-load-after
    snake            macro: munch every square of the 6x5 board in a snake
    clear-levels 12  play from the first board: clear 12 levels (board_solver.py),
                     then end the game; the next key is typed at name entry
    poll $D179       also count keyboard polls here from the first run (saves
                     re-solving levels when discovery would find the site later)
    expect-load-after mode   the disk must be read after the marked key

Each new screen may poll the keyboard from a site not seen before, so the run
is repeated, adding every keyboard-read site found in the collected code,
until no new site appears. The final run is done twice and must match.
Writes OUT_DIR/{collect.json,probe.out,session.json}. Exit 1 on failure.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

DEFAULT_WAIT = 300
GAMEPLAY_WAIT = 30
END_WAIT = 3000
MAX_FRAMES = 400000
MAX_DISCOVERY_RUNS = 8
RUN_TIMEOUT_SECONDS = 600
SOLVER_TIMEOUT_SECONDS = 3600
BOARD_COLUMNS = 6
BOARD_ROWS = 5
KEYBOARD = 0xC000
# Keyboard reads already known from Stage 3 and the Stage 4 exploration.
SEED_POLL_SITES = {0x0BC0, 0x0CC2, 0x1404, 0x1E95, 0x838D, 0x975A, 0x97DF, 0xA194}
# Added by a session's "poll" lines, so a long session can start from sites found earlier.
extra_poll_sites: set[int] = set()
# The loader's sector reader; see tools/30_capture.sh.
SECTOR_READER = 0xBBF4
KEY_NAMES = {"RETURN": 13, "SPACE": 32, "ESC": 27, "LEFT": 8, "RIGHT": 21, "DOWN": 10,
             "UP": 11, "CTRL-S": 19, "QUESTION": 63}
OPERAND_SIZES = {"imp": 0, "acc": 0, "imm": 1, "zp": 1, "zpx": 1, "zpy": 1, "izx": 1,
                 "izy": 1, "rel": 1, "abs": 2, "abx": 2, "aby": 2, "ind": 2}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def key_code(token: str) -> int:
    if token.upper() in KEY_NAMES:
        return KEY_NAMES[token.upper()]
    if len(token) == 1:
        return ord(token.upper())
    if token.isdigit():
        return int(token)
    fail(f"unknown key '{token}'")
    return 0


def snake_keys() -> list[tuple[int, int]]:
    """Munch, then step: right along row 1, left along row 2, and so on."""
    keys: list[tuple[int, int]] = []
    for row in range(BOARD_ROWS):
        step = KEY_NAMES["RIGHT"] if row % 2 == 0 else KEY_NAMES["LEFT"]
        for _ in range(BOARD_COLUMNS - 1):
            keys += [(KEY_NAMES["SPACE"], GAMEPLAY_WAIT), (step, GAMEPLAY_WAIT)]
        keys += [(KEY_NAMES["SPACE"], GAMEPLAY_WAIT), (KEY_NAMES["DOWN"], GAMEPLAY_WAIT)]
    return keys


def parse_session(path: Path) -> tuple[list[tuple[int, int]], dict[str, int], list[str], tuple[int, int] | None]:
    """Returns (keys as (code, wait)), marks (name -> 1-based key number), expectations,
    and (key index, levels) of a clear-levels directive, if any."""
    keys: list[tuple[int, int]] = []
    marks: dict[str, int] = {}
    expectations: list[str] = []
    clear_levels: tuple[int, int] | None = None
    extra_poll_sites.clear()
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        words = raw.split("#", 1)[0].split()
        if not words:
            continue
        if words[0] == "snake":
            keys += snake_keys()
        elif words[0] == "clear-levels" and len(words) == 2 and words[1].isdigit() and clear_levels is None:
            clear_levels = (len(keys), int(words[1]))
        elif words[0] == "poll" and len(words) > 1 and all(w.startswith("$") for w in words[1:]):
            extra_poll_sites.update(int(word[1:], 16) for word in words[1:])
        elif words[0] == "mark" and len(words) == 2:
            marks[words[1]] = len(keys) + 1
        elif words[0] == "expect-load-after" and len(words) == 2:
            expectations.append(words[1])
        elif len(words) in (1, 2):
            keys.append((key_code(words[0]), int(words[1]) if len(words) == 2 else DEFAULT_WAIT))
        else:
            fail(f"{path}:{number}: cannot parse '{raw.strip()}'")
    for name in expectations:
        if name not in marks:
            fail(f"{path}: expect-load-after {name} has no matching mark")
    if not keys:
        fail(f"{path}: no keys")
    if clear_levels is not None and any(key > clear_levels[0] for key in marks.values()):
        fail(f"{path}: a mark after clear-levels would point at a solver key")
    return keys, marks, expectations, clear_levels


def solve_levels(keys: list[tuple[int, int]], clear_levels: tuple[int, int] | None, poll_sites: set[int],
                 out_dir: Path, tools: tuple[str, str, str]) -> tuple[list[tuple[int, int]], dict[str, Any] | None]:
    """Expand a clear-levels directive into keys with board_solver.py, once per poll-site set."""
    if clear_levels is None:
        return keys, None
    position, levels = clear_levels
    sites = ",".join(f"{site:04X}" for site in sorted(poll_sites))
    solver_dir = out_dir / "solver" / hashlib.sha256(sites.encode()).hexdigest()[:12]
    if not (solver_dir / "solver.json").exists():
        solver_dir.mkdir(parents=True, exist_ok=True)
        (solver_dir / "prefix.keys").write_text("".join(f"{code} {wait}\n" for code, wait in keys[:position]))
        command = [sys.executable, "-I", str(Path(__file__).resolve().parent / "board_solver.py"),
                   str(solver_dir / "prefix.keys"), str(levels), str(solver_dir), *tools, sites]
        result = subprocess.run(command, capture_output=True, text=True, timeout=SOLVER_TIMEOUT_SECONDS)
        if result.returncode != 0:
            fail(f"board_solver.py: {result.stderr.strip().splitlines()[-1:]}")
    solved = [(int(code), int(wait)) for code, wait in
              (line.split() for line in (solver_dir / "solved.keys").read_text().splitlines() if line.strip())]
    return solved + keys[position:], json.loads((solver_dir / "solver.json").read_text())["result"]


def write_probe(path: Path, keys: list[tuple[int, int]], poll_sites: set[int]) -> None:
    lines = ["counter idle", "counter keyno", "counter reported", "", "probe poll(site = pc) {", "  inc idle"]
    for index, (_, wait) in enumerate(keys):
        lines.append(f"  if (keyno == {index} && idle >= {wait}) {{ inc keyno  idle = 0  key keyno }}")
    lines += ["  if (keyno != reported) { reported = keyno  printf(\"key %u site %04X\\n\", keyno, site) }",
              f"  if (keyno == {len(keys)} && idle >= {END_WAIT}) {{ printf(\"end site %04X\\n\", site)  stop }}",
              "}", "",
              "probe sector(site = pc) {",
              "  printf(\"sector key %u track %u sector %u buffer %04X\\n\", keyno, peek8($B9C9), peek8($B9C8), peek16($2E))",
              "}", "",
              "install poll at " + ", ".join(f"${site:04X}" for site in sorted(poll_sites)),
              f"install sector at ${SECTOR_READER:04X}"]
    path.write_text("\n".join(lines) + "\n")


def run_emulator(paths: dict[str, Path], emulator: str, rom: str, disk: str) -> None:
    for name in ("collect", "probe_out"):
        paths[name].unlink(missing_ok=True)
    command = [emulator, f"--rom={rom}", f"--disk1={disk}", "--headless", "--no-sound", f"--frames={MAX_FRAMES}",
               f"--key-file={paths['keys']}", f"--probe={paths['probe']}", f"--probe-out={paths['probe_out']}",
               "--collect", "--from-rom", f"--out={paths['collect']}"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=RUN_TIMEOUT_SECONDS)
    if result.returncode != 0 or not paths["collect"].exists():
        errors = [line for line in result.stderr.splitlines() if "Unsupported IO" not in line]
        fail(f"a2emu exited {result.returncode}: {' | '.join(errors[-3:])}")


def load_opcode_table() -> dict[int, tuple[str, str]]:
    analyzer_path = Path(__file__).resolve().parent.parent / "10_analyze.py"
    spec = importlib.util.spec_from_file_location("analyzer", analyzer_path)
    if spec is None or spec.loader is None:
        fail(f"cannot load {analyzer_path}")
    analyzer = importlib.util.module_from_spec(spec)
    sys.modules["analyzer"] = analyzer
    spec.loader.exec_module(analyzer)
    return analyzer.build_opcode_table()


def keyboard_read_sites(collect_path: Path, opcode_table: dict[int, tuple[str, str]]) -> set[int]:
    """Addresses of executed instructions that read $C000 directly or indexed."""
    sites: set[int] = set()
    for generation in json.loads(collect_path.read_text())["generations"]:
        for run in generation["code"]:
            start = int(run["addr"])
            code = json.loads(run["bytes"]) if isinstance(run["bytes"], str) else run["bytes"]
            offset = 0
            while offset < len(code) and code[offset] in opcode_table:
                mnemonic, mode = opcode_table[code[offset]]
                size = OPERAND_SIZES[mode]
                if offset + size >= len(code):
                    break
                if size == 2 and mode in ("abs", "abx") and mnemonic != "STA" and \
                        code[offset + 1] | code[offset + 2] << 8 == KEYBOARD:
                    sites.add(start + offset)
                offset += 1 + size
    return sites


def summarise(probe_out: Path, keys_total: int) -> dict[str, Any]:
    delivered = 0
    ended = False
    sectors: list[dict[str, int]] = []
    for line in probe_out.read_text().splitlines():
        fields = line.split()
        if fields[:1] == ["key"] and len(fields) == 4:
            delivered = max(delivered, int(fields[1]))
        elif fields[:1] == ["end"]:
            ended = True
        elif fields[:2] == ["sector", "key"] and len(fields) == 9:
            sectors.append({"after_key": int(fields[2]), "track": int(fields[4]),
                            "sector": int(fields[6]), "buffer": int(fields[8], 16)})
    return {"keys_total": keys_total, "keys_delivered": delivered, "ended_cleanly": ended, "sectors": sectors}


def main() -> int:
    if len(sys.argv) != 6:
        print(__doc__, file=sys.stderr)
        return 1
    session_file, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    emulator, rom, disk = sys.argv[3:6]
    session_keys, marks, expectations, clear_levels = parse_session(session_file)
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = {"keys": out_dir / "session.keys", "probe": out_dir / "session.probe",
             "probe_out": out_dir / "probe.out", "collect": out_dir / "collect.json"}
    opcode_table = load_opcode_table()

    poll_sites = SEED_POLL_SITES | extra_poll_sites
    for discovery_run in range(1, MAX_DISCOVERY_RUNS + 1):
        keys, solver = solve_levels(session_keys, clear_levels, poll_sites, out_dir, (emulator, rom, disk))
        paths["keys"].write_text("".join(f"{index} {code}\n" for index, (code, _) in enumerate(keys, 1)))
        write_probe(paths["probe"], keys, poll_sites)
        run_emulator(paths, emulator, rom, disk)
        found = keyboard_read_sites(paths["collect"], opcode_table)
        if found <= poll_sites:
            break
        poll_sites |= found
    else:
        fail(f"keyboard-read sites still changing after {MAX_DISCOVERY_RUNS} runs")

    first_hashes = {name: hashlib.sha256(paths[name].read_bytes()).hexdigest() for name in ("collect", "probe_out")}
    run_emulator(paths, emulator, rom, disk)
    second_hashes = {name: hashlib.sha256(paths[name].read_bytes()).hexdigest() for name in ("collect", "probe_out")}

    summary = summarise(paths["probe_out"], len(keys))
    summary.update({
        "session": session_file.stem,
        "discovery_runs": discovery_run,
        "poll_sites": [f"${site:04X}" for site in sorted(poll_sites)],
        "deterministic": first_hashes == second_hashes,
        "collect_sha256": second_hashes["collect"],
        "levels": solver,
        "marks": marks,
        "expectations": [{"load_after": name,
                          "met": any(s["after_key"] >= marks[name] for s in summary["sectors"])}
                         for name in expectations],
    })
    (out_dir / "session.json").write_text(json.dumps(summary, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
