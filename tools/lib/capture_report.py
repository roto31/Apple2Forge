"""Summarise a Stage 3 capture folder written by tools/30_capture.sh.

Usage: python3 -I tools/lib/capture_report.py CAPTURE_DIR ROM_FILE

CAPTURE_DIR holds, per capture point NAME listed in points.txt ("NAME HEXADDR"):
  NAME (64K RAM), NAME.regs, NAME.lc (Language Card), NAME.disk (Disk II state)
plus sectors.out (sector-read probe log) and collect.json (a2emu --collect).
Writes capture.json and capture.md to CAPTURE_DIR. Never copies RAM, ROM or
disk bytes into the report: only addresses, counts, flags and hashes.
Exit 1 on missing or malformed input.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any

RAM_SIZE = 0x10000
PAGE_SIZE = 0x100
ROM_BASE = 0xD000
ROM_SIZE = 0x3000
LC_MAGIC = b"A2LC"
LC_HEADER_BYTES = 8
LC_BANK_SIZE = 0x1000
LC_HIGH_SIZE = 0x2000
LC_FLAGS = {"read_ram": 0x01, "bank2": 0x02, "write_enabled": 0x04, "prewrite": 0x08}
SOFT_SWITCH_LOW = 0xC000
SOFT_SWITCH_HIGH = 0xC0FF
DISK_SLOT_BASE = 0xC080
PHASE_NAMES = {0: "boot (before $3000)", 1: "loader ($3000 to title)", 2: "title to game start"}

SOFT_SWITCH_NAMES = {
    0xC000: "KBD", 0xC010: "KBDSTRB", 0xC030: "SPKR",
    0xC050: "TXTCLR", 0xC051: "TXTSET", 0xC052: "MIXCLR", 0xC053: "MIXSET",
    0xC054: "LOWSCR", 0xC055: "HISCR", 0xC056: "LORES", 0xC057: "HIRES",
    0xC061: "BUTN0", 0xC062: "BUTN1", 0xC063: "BUTN2",
    0xC064: "PADDL0", 0xC065: "PADDL1", 0xC066: "PADDL2", 0xC067: "PADDL3", 0xC070: "PTRIG",
}
MONITOR_ENTRY_NAMES = {
    0xF800: "PLOT", 0xF819: "HLINE", 0xF828: "VLINE", 0xF832: "CLRSCR", 0xF836: "CLRTOP",
    0xF847: "GBASCALC", 0xF864: "SETCOL", 0xFB1E: "PREAD", 0xFB2F: "INIT", 0xFB39: "SETTXT",
    0xFB40: "SETGR", 0xFBDD: "BELL1", 0xFC22: "VTAB", 0xFC42: "CLREOP", 0xFC58: "HOME",
    0xFC9C: "CLREOL", 0xFCA8: "WAIT", 0xFD0C: "RDKEY", 0xFD1B: "KEYIN", 0xFD6A: "GETLN",
    0xFD8E: "CROUT", 0xFDDA: "PRBYTE", 0xFDED: "COUT", 0xFDF0: "COUT1", 0xFE84: "SETNORM",
    0xFE89: "SETKBD", 0xFE93: "SETVID", 0xFF3A: "BELL", 0xFF59: "OLDRST", 0xFF69: "MON",
}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def read_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) == 2:
            values[parts[0]] = parts[1]
    return values


def page_ranges(pages: list[int]) -> list[str]:
    """Collapse sorted page numbers into "$hh00-$hhFF" ranges."""
    ranges: list[str] = []
    start = previous = None
    for page in pages + [None]:
        if page is not None and previous is not None and page == previous + 1:
            previous = page
            continue
        if start is not None:
            ranges.append(f"${start:02X}00-${previous:02X}FF")
        start = previous = page
    return ranges


def describe_language_card(path: Path, rom: bytes) -> dict[str, Any]:
    if not path.exists():
        return {"present": False}
    data = path.read_bytes()
    if len(data) != LC_HEADER_BYTES + 2 * LC_BANK_SIZE + LC_HIGH_SIZE or data[:4] != LC_MAGIC:
        fail(f"{path} is not a Language Card state file")
    flags = data[5]
    bank1 = data[LC_HEADER_BYTES:LC_HEADER_BYTES + LC_BANK_SIZE]
    bank2 = data[LC_HEADER_BYTES + LC_BANK_SIZE:LC_HEADER_BYTES + 2 * LC_BANK_SIZE]
    high = data[LC_HEADER_BYTES + 2 * LC_BANK_SIZE:]
    rom_bank, rom_high = rom[:LC_BANK_SIZE], rom[LC_BANK_SIZE:]

    def bytes_differing(ram: bytes, reference: bytes) -> int:
        return sum(1 for a, b in zip(ram, reference) if a != b)

    return {
        "present": True,
        "flags": {name: bool(flags & bit) for name, bit in LC_FLAGS.items()},
        "bytes_differing_from_rom": {
            "bank1_D000": bytes_differing(bank1, rom_bank),
            "bank2_D000": bytes_differing(bank2, rom_bank),
            "high_E000": bytes_differing(high, rom_high),
        },
    }


def describe_point(capture_dir: Path, name: str, address: int, rom: bytes,
                   previous_ram: bytes | None) -> tuple[dict[str, Any], bytes]:
    ram_path = capture_dir / name
    for suffix in ("", ".regs", ".lc", ".disk"):
        if not Path(f"{ram_path}{suffix}").exists():
            fail(f"capture {name} is missing {ram_path}{suffix}")
    ram = ram_path.read_bytes()
    if len(ram) != RAM_SIZE:
        fail(f"{ram_path} is {len(ram)} bytes, expected {RAM_SIZE}")
    regs = read_key_values(Path(f"{ram_path}.regs"))
    pages = [ram[p * PAGE_SIZE:(p + 1) * PAGE_SIZE] for p in range(RAM_SIZE // PAGE_SIZE)]
    nonzero = [p for p, data in enumerate(pages) if any(data)]
    point: dict[str, Any] = {
        "name": name,
        "capture_address": f"${address:04X}",
        "pc": f"${regs.get('pc', '????')}",
        "cycles": int(regs.get("cycles", "0")),
        "video": {"mode": regs.get("vidmode"), "page": regs.get("vidpage"), "mixed": regs.get("mixed")},
        "ram_sha256": hashlib.sha256(ram).hexdigest(),
        "nonzero_pages": page_ranges(nonzero),
        "language_card": describe_language_card(Path(f"{ram_path}.lc"), rom),
        "disk2": read_key_values(Path(f"{ram_path}.disk")),
    }
    if previous_ram is not None:
        changed = [p for p in range(RAM_SIZE // PAGE_SIZE)
                   if previous_ram[p * PAGE_SIZE:(p + 1) * PAGE_SIZE] != pages[p]]
        point["pages_changed_since_previous"] = page_ranges(changed)
    return point, ram


def summarise_sector_reads(path: Path) -> list[dict[str, Any]]:
    """sectors.out lines: "sector N phase P track T sector S buffer HHHH"."""
    phases: dict[int, dict[str, Any]] = {}
    for line in path.read_text().splitlines():
        fields = line.split()
        if len(fields) != 10 or fields[0] != "sector":
            continue
        phase, track, buffer_page = int(fields[3]), int(fields[5]), int(fields[9], 16) >> 8
        entry = phases.setdefault(phase, {"sectors": 0, "tracks": set(), "pages": set()})
        entry["sectors"] += 1
        entry["tracks"].add(track)
        entry["pages"].add(buffer_page)
    if not phases:
        fail(f"{path} has no sector reads")
    return [{
        "phase": phase,
        "description": PHASE_NAMES.get(phase, "after game start"),
        "sectors": entry["sectors"],
        "tracks": sorted(entry["tracks"]),
        "destination_pages": page_ranges(sorted(entry["pages"])),
    } for phase, entry in sorted(phases.items())]


def decode_operands(code_bytes: list[int], start: int, opcode_table: dict[int, tuple[str, str]]):
    """Yield (address, mnemonic, mode, operand) through one executed run."""
    operand_sizes = {"imp": 0, "acc": 0, "imm": 1, "zp": 1, "zpx": 1, "zpy": 1, "izx": 1,
                     "izy": 1, "rel": 1, "abs": 2, "abx": 2, "aby": 2, "ind": 2}
    offset = 0
    while offset < len(code_bytes):
        entry = opcode_table.get(code_bytes[offset])
        if entry is None:
            return
        mnemonic, mode = entry
        size = operand_sizes[mode]
        if offset + size >= len(code_bytes):
            return
        operand = None
        if size == 1:
            operand = code_bytes[offset + 1]
        elif size == 2:
            operand = code_bytes[offset + 1] | code_bytes[offset + 2] << 8
        yield start + offset, mnemonic, mode, operand
        offset += 1 + size


def soft_switch_label(operand: int, mode: str) -> str:
    if DISK_SLOT_BASE <= operand <= 0xC08F and mode == "abx":
        return f"${operand:04X},X (Disk II, slot in X)"
    if 0xC080 <= operand <= 0xC08F:
        return f"${operand:04X} (Language Card)"
    if 0xC0E0 <= operand <= 0xC0EF:
        return f"${operand:04X} (Disk II slot 6)"
    if mode != "abs":
        return f"${operand:04X}," + ("X" if mode == "abx" else "Y")
    name = SOFT_SWITCH_NAMES.get(operand)
    return f"${operand:04X}" + (f" ({name})" if name else "")


def summarise_dependencies(path: Path, rom: bytes, opcode_table: dict[int, tuple[str, str]]) -> list[dict[str, Any]]:
    collect = json.loads(path.read_text())
    generations = collect.get("generations")
    if not isinstance(generations, list) or not generations:
        fail(f"{path} has no generations")
    summary: list[dict[str, Any]] = []
    for index, generation in enumerate(generations):
        switches: set[str] = set()
        rom_calls: set[str] = set()
        same_as_rom = differing_from_rom = 0
        for run in generation["code"]:
            start = int(run["addr"])
            code_bytes = json.loads(run["bytes"]) if isinstance(run["bytes"], str) else run["bytes"]
            if start >= ROM_BASE:
                matches_rom = bytes(code_bytes) == rom[start - ROM_BASE:start - ROM_BASE + len(code_bytes)]
                if matches_rom:
                    same_as_rom += len(code_bytes)
                else:
                    differing_from_rom += len(code_bytes)
            for _, mnemonic, mode, operand in decode_operands(code_bytes, start, opcode_table):
                if operand is None or mode not in ("abs", "abx", "aby"):
                    continue
                if SOFT_SWITCH_LOW <= operand <= SOFT_SWITCH_HIGH:
                    switches.add(soft_switch_label(operand, mode))
                if mnemonic in ("JSR", "JMP") and operand >= 0xF800:
                    name = MONITOR_ENTRY_NAMES.get(operand)
                    rom_calls.add(f"${operand:04X}" + (f" ({name})" if name else ""))
        regs = generation.get("regs") or {}
        summary.append({
            "generation": index,
            "pc_at_start": f"${regs['pc']:04X}" if "pc" in regs else None,
            "executed_runs": len(generation["code"]),
            "code_bytes_D000_up_same_as_rom": same_as_rom,
            "code_bytes_D000_up_differing_from_rom": differing_from_rom,
            "soft_switches": sorted(switches),
            "calls_into_F800_FFFF": sorted(rom_calls),
        })
    return summary


def load_opcode_table() -> dict[int, tuple[str, str]]:
    import importlib.util
    analyzer_path = Path(__file__).resolve().parent.parent / "10_analyze.py"
    spec = importlib.util.spec_from_file_location("analyzer", analyzer_path)
    if spec is None or spec.loader is None:
        fail(f"cannot load {analyzer_path}")
    analyzer = importlib.util.module_from_spec(spec)
    sys.modules["analyzer"] = analyzer
    spec.loader.exec_module(analyzer)
    return analyzer.build_opcode_table()


def write_markdown(report: dict[str, Any], path: Path) -> None:
    lines = ["# Stage 3 capture report", "",
             "Personal-use analysis of a user-supplied disk. Contains no RAM, ROM or disk bytes.", "",
             "## Capture points", "",
             "| Point | Address | PC | Cycles | Video | LC read/bank2/write | Nonzero pages |",
             "|---|---|---|---|---|---|---|"]
    for point in report["points"]:
        lc = point["language_card"]
        lc_text = "/".join("y" if lc["flags"][k] else "n" for k in ("read_ram", "bank2", "write_enabled")) if lc["present"] else "absent"
        video = point["video"]
        lines.append(f"| {point['name']} | {point['capture_address']} | {point['pc']} | {point['cycles']} | "
                     f"{video['mode']} p{video['page']} | {lc_text} | {', '.join(point['nonzero_pages'])} |")
    lines += ["", "## Disk reads by phase", "", "| Phase | Sectors | Tracks | Destination pages |", "|---|---|---|---|"]
    for phase in report["disk_reads"]:
        lines.append(f"| {phase['description']} | {phase['sectors']} | {', '.join(map(str, phase['tracks']))} | "
                     f"{', '.join(phase['destination_pages'])} |")
    lines += ["", "## Code generations (ROM and soft-switch dependencies)", ""]
    for generation in report["dependencies"]:
        lines.append(f"- Generation {generation['generation']} (PC {generation['pc_at_start']} when it began): "
                     f"executed code at $D000+: {generation['code_bytes_D000_up_same_as_rom']} bytes same as ROM, "
                     f"{generation['code_bytes_D000_up_differing_from_rom']} differing (card RAM); "
                     f"soft switches: {', '.join(generation['soft_switches']) or 'none'}; "
                     f"calls into $F800-$FFFF: {', '.join(generation['calls_into_F800_FFFF']) or 'none'}")
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    capture_dir, rom_path = Path(sys.argv[1]), Path(sys.argv[2])
    rom = rom_path.read_bytes()
    if len(rom) != ROM_SIZE:
        fail(f"{rom_path} is {len(rom)} bytes, expected {ROM_SIZE} ($D000-$FFFF)")
    points_file = capture_dir / "points.txt"
    if not points_file.exists():
        fail(f"missing {points_file}")
    points: list[dict[str, Any]] = []
    previous_ram: bytes | None = None
    for line in points_file.read_text().splitlines():
        if not line.strip():
            continue
        name, address_text = line.split()
        point, previous_ram = describe_point(capture_dir, name, int(address_text, 16), rom, previous_ram)
        points.append(point)
    report = {
        "points": points,
        "disk_reads": summarise_sector_reads(capture_dir / "sectors.out"),
        "dependencies": summarise_dependencies(capture_dir / "collect.json", rom, load_opcode_table()),
    }
    (capture_dir / "capture.json").write_text(json.dumps(report, indent=2) + "\n")
    write_markdown(report, capture_dir / "capture.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
