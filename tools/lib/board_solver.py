"""Clear Number Munchers levels using the game's own answer table.

Usage: python3 -I tools/lib/board_solver.py PREFIX_KEYS LEVELS OUT_DIR EMULATOR ROM DISK [SITES]
       PREFIX_KEYS: lines "CODE WAIT", the keys that reach the first board.
       SITES: comma-separated hex keyboard-poll sites to count polls at. Must be the
       set the replaying session installs, or keys land at different moments.

The game keeps one byte per square at $9974 + row * 6 + column, with bit 7 set
for a right answer and 0 once eaten (Multiples: $FF right, $7F wrong; Factors:
the value itself, $83 = 3 right, $02 = 2 wrong). The muncher's column and row
are at $9AA5 and $9AA6; the level, in BCD, at $9AC4. Since the game marks its
own right answers, no maths is needed here, in any mode.

Each step replays the whole game from boot with probe-delivered keys (exact,
see coverage_session.py), stops once the game has polled the keyboard
SETTLE_WAIT times after the last key, and reads the state. The next keys are
planned from that state and appended. Because replays are exact, the keys found
this way replay to the same game every time.

After LEVELS levels (or when the lives run out) the game is ended with Esc Esc
and played on to Hall of Fame name entry, so the caller continues from there.
Writes OUT_DIR/solved.keys ("CODE WAIT" lines, prefix included) and
OUT_DIR/solver.json (result + per-step log). Exit 0 when done, 1 on error.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

BOARD_TABLE = 0x9974
MUNCHER_COLUMN = 0x9AA5
MUNCHER_ROW = 0x9AA6
LEVEL = 0x9AC4
STATE_BLOCK = 0x9AA0
PLAY_SITE = 0x975A
NAME_ENTRY_SITE = 0x838D
MESSAGE_SITE = 0x97DF
RETRY_DELAYS = (30, 90, 240, 600)
RETRY_TARGETS = 3
STATE_BLOCK_BYTES = 48
BOARD_COLUMNS = 6
BOARD_ROWS = 5
RIGHT_ANSWER_BIT = 0x80
DEFAULT_POLL_SITES = {0x0B52, 0x0BC0, 0x0CC2, 0x1404, 0x1A8A, 0x1E95, 0x838D, 0x895F, 0x975A, 0x97DF, 0xA194}
poll_sites = set(DEFAULT_POLL_SITES)
KEYS = {"SPACE": 32, "LEFT": 8, "RIGHT": 21, "DOWN": 10, "UP": 11, "ESC": 27}
MAX_END_STEPS = 6
MOVE_WAIT = 30
SETTLE_WAIT = 150
MAX_STEPS = 400
MAX_FRAMES = 400000
RUN_TIMEOUT_SECONDS = 600


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def write_probe(path: Path, keys: list[tuple[int, int]]) -> None:
    table_args = ", ".join(f"peek8(${BOARD_TABLE + i:04X})" for i in range(BOARD_COLUMNS * BOARD_ROWS))
    block_args = ", ".join(f"peek16(${STATE_BLOCK + i:04X})" for i in range(0, STATE_BLOCK_BYTES, 2))
    lines = ["counter idle", "counter keyno", "counter last_site", "counter messages",
             "probe poll(site = pc) {", "  inc idle",
             f"  if (site == ${MESSAGE_SITE:04X} && last_site != ${MESSAGE_SITE:04X}) {{ inc messages }}",
             "  last_site = site"]
    lines += [f"  if (keyno == {index} && idle >= {wait}) {{ inc keyno  idle = 0  key keyno }}"
              for index, (_, wait) in enumerate(keys)]
    lines += [f"  if (keyno == {len(keys)} && idle >= {SETTLE_WAIT}) {{",
              f"    printf(\"state %04X %u %u %u\\n\", site, peek8(${MUNCHER_COLUMN:04X}), peek8(${MUNCHER_ROW:04X}),"
              " messages)",
              "    printf(\"table" + " %u" * (BOARD_COLUMNS * BOARD_ROWS) + "\\n\", " + table_args + ")",
              "    printf(\"block" + " %04X" * (STATE_BLOCK_BYTES // 2) + "\\n\", " + block_args + ")",
              "    stop", "  }", "}",
              "install poll at " + ", ".join(f"${site:04X}" for site in sorted(poll_sites))]
    path.write_text("\n".join(lines) + "\n")


def read_state(keys: list[tuple[int, int]], out_dir: Path, tools: tuple[str, str, str]) -> dict[str, Any]:
    emulator, rom, disk = tools
    probe, key_file, probe_out = out_dir / "solver.probe", out_dir / "solver.keys", out_dir / "solver.out"
    write_probe(probe, keys)
    key_file.write_text("".join(f"{index} {code}\n" for index, (code, _) in enumerate(keys, 1)))
    probe_out.unlink(missing_ok=True)
    command = [emulator, f"--rom={rom}", f"--disk1={disk}", "--headless", "--no-sound", f"--frames={MAX_FRAMES}",
               f"--key-file={key_file}", f"--probe={probe}", f"--probe-out={probe_out}"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=RUN_TIMEOUT_SECONDS)
    lines = probe_out.read_text().split("\n") if probe_out.exists() else []
    fields = {line.split()[0]: line.split()[1:] for line in lines if line.strip()}
    if "state" not in fields:
        errors = [line for line in result.stderr.splitlines() if "Unsupported IO" not in line]
        fail(f"no state after {len(keys)} keys (exit {result.returncode}): {' | '.join(errors[-3:])}")
    block = bytes(b for word in fields["block"] for b in (int(word, 16) & 0xFF, int(word, 16) >> 8))
    return {"site": int(fields["state"][0], 16), "column": int(fields["state"][1]), "row": int(fields["state"][2]),
            "messages": int(fields["state"][3]), "table": [int(v) for v in fields["table"]], "block": block}


def right_answers(state: dict[str, Any]) -> list[tuple[int, int]]:
    """(column, row) of every uneaten right answer, nearest to the muncher first."""
    squares = [(index % BOARD_COLUMNS, index // BOARD_COLUMNS)
               for index, value in enumerate(state["table"]) if value & RIGHT_ANSWER_BIT]
    return sorted(squares, key=lambda s: (abs(s[0] - state["column"]) + abs(s[1] - state["row"]), s[1], s[0]))


def path_to(state: dict[str, Any], target: tuple[int, int], first_wait: int) -> list[tuple[int, int]]:
    """Moves to the target square (columns first), then munch. The first key waits first_wait polls."""
    keys: list[tuple[int, int]] = []
    column, row = state["column"], state["row"]
    while column != target[0]:
        keys.append((KEYS["RIGHT"] if target[0] > column else KEYS["LEFT"], MOVE_WAIT))
        column += 1 if target[0] > column else -1
    while row != target[1]:
        keys.append((KEYS["DOWN"] if target[1] > row else KEYS["UP"], MOVE_WAIT))
        row += 1 if target[1] > row else -1
    keys.append((KEYS["SPACE"], MOVE_WAIT))
    keys[0] = (keys[0][0], first_wait)
    return keys


def level(state: dict[str, Any]) -> int:
    """The level byte is BCD."""
    value = state["block"][LEVEL - STATE_BLOCK]
    return (value >> 4) * 10 + (value & 0x0F)


def munched(before: dict[str, Any], after: dict[str, Any], target: tuple[int, int]) -> bool:
    """No message screen (a Troggle ate the muncher) since the last state. A Troggle may also have
    changed the target square; that is fine, the next step plans from the new board."""
    del target
    return after["messages"] == before["messages"]


def munch_next(keys: list[tuple[int, int]], state: dict[str, Any], out_dir: Path,
               tools: tuple[str, str, str]) -> tuple[list[tuple[int, int]], dict[str, Any], bool]:
    """Try the nearest targets with growing delays; returns (keys, state, clean).
    If every try ends with the muncher eaten, the first try is kept (a life is lost)."""
    first: tuple[list[tuple[int, int]], dict[str, Any]] | None = None
    for delay in RETRY_DELAYS:
        for target in right_answers(state)[:RETRY_TARGETS]:
            trial = keys + path_to(state, target, delay)
            after = read_state(trial, out_dir, tools)
            if munched(state, after, target):
                return trial, after, True
            if first is None:
                first = (trial, after)
    assert first is not None
    return first[0], first[1], False


def main() -> int:
    if len(sys.argv) not in (7, 8):
        print(__doc__, file=sys.stderr)
        return 1
    prefix_path, levels, out_dir = Path(sys.argv[1]), int(sys.argv[2]), Path(sys.argv[3])
    tools = (sys.argv[4], sys.argv[5], sys.argv[6])
    if len(sys.argv) == 8:
        poll_sites.clear()
        poll_sites.update(int(site.lstrip("$"), 16) for site in sys.argv[7].split(","))
    missing = {PLAY_SITE, MESSAGE_SITE, NAME_ENTRY_SITE} - poll_sites
    if missing:
        fail("SITES must include " + ", ".join(f"${site:04X}" for site in sorted(missing)))
    out_dir.mkdir(parents=True, exist_ok=True)
    keys = [(int(code), int(wait)) for code, wait in (line.split() for line in prefix_path.read_text().splitlines()
                                                     if line.strip())]
    state = read_state(keys, out_dir, tools)
    start_level = level(state)
    log: list[dict[str, Any]] = []
    lives_lost = 0
    for step in range(MAX_STEPS):
        if level(state) >= start_level + levels or state["site"] == NAME_ENTRY_SITE:
            break
        if state["site"] == PLAY_SITE and not right_answers(state):
            fail(f"on the board after {len(keys)} keys with no right answer in the table")
        if state["site"] == PLAY_SITE:
            keys, state, clean = munch_next(keys, state, out_dir, tools)
            lives_lost += not clean
        else:
            keys = keys + [(KEYS["SPACE"], SETTLE_WAIT)]
            state = read_state(keys, out_dir, tools)
        entry = {"step": step, "keys": len(keys), "site": f"${state['site']:04X}", "level": level(state),
                 "column": state["column"], "row": state["row"], "right_left": len(right_answers(state)),
                 "lives_lost": lives_lost}
        log.append(entry)
        print(json.dumps(entry), flush=True)
    end_level, ran_out_of_lives = level(state), state["site"] == NAME_ENTRY_SITE
    keys, state = end_game(keys, state, out_dir, tools)
    result = {"start_level": start_level, "end_level": end_level, "levels_cleared": end_level - start_level,
              "lives_lost": lives_lost, "ran_out_of_lives": ran_out_of_lives, "keys": len(keys)}
    (out_dir / "solved.keys").write_text("".join(f"{code} {wait}\n" for code, wait in keys))
    (out_dir / "solver.json").write_text(json.dumps({"result": result, "log": log}, indent=2) + "\n")
    print(json.dumps(result))
    return 0


def end_game(keys: list[tuple[int, int]], state: dict[str, Any], out_dir: Path,
             tools: tuple[str, str, str]) -> tuple[list[tuple[int, int]], dict[str, Any]]:
    """Esc twice ends a game in play; Space continues past any other screen (between levels,
    Congratulations), until Hall of Fame name entry."""
    escaped = False
    for _ in range(MAX_END_STEPS):
        if state["site"] == NAME_ENTRY_SITE:
            return keys, state
        if state["site"] == PLAY_SITE:
            if escaped:
                fail(f"Esc Esc did not end the game after {len(keys)} keys")
            keys = keys + [(KEYS["ESC"], MOVE_WAIT), (KEYS["ESC"], MOVE_WAIT)]
            escaped = True
        else:
            keys = keys + [(KEYS["SPACE"], SETTLE_WAIT)]
        state = read_state(keys, out_dir, tools)
    fail(f"no Hall of Fame name entry within {MAX_END_STEPS} keys after the game")
    return keys, state


if __name__ == "__main__":
    sys.exit(main())
