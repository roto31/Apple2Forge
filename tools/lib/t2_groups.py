"""Split the code the sessions executed into overlay groups for apple2tc.

Usage: python3 -I tools/lib/t2_groups.py OUT_DIR ROM START_REGS SITES COLLECT_JSON...
       ROM: the user's 12K ROM, used only to drop code that ran from it.
       START_REGS: the start image's .regs (its pc seeds apple2tc).
       SITES: comma-separated hex addresses that must start a block (the
       keyboard-poll sites probes install at, since probes fire at block heads).

The game loads different code into the same addresses as it runs (one overlay
per game mode, plus code it rewrites), so one disassembly cannot hold it all.
Every executed segment from every session is decoded and placed in the first
group whose instructions do not clash with it: same opcode bytes at the same
instruction starts. Operand-only differences are self-modified operands, not a
different program, and stay in one group. Each group is then topped up from
the others where it has no code, so writers of self-modified code are visible
to every group.

Dropped: segments at $C000-$CFFF or $F800-$FFFF (boot PROM and Monitor), any in
$D000-$F7FF identical to the ROM (ROM code), and any that do not decode (data
the collector saw through the other Language Card bank).

Writes OUT_DIR/gN.b33 ($0100-$FFFF image), OUT_DIR/gN.json (run data),
OUT_DIR/gN.opcodes.json (executed instruction starts) and OUT_DIR/groups.json.
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

IMAGE_START = 0x0100
CODE_END = 0xF800
# The image runs to $FFFF, Monitor area zero, because apple2tc loads its own
# built-in ROM for any branch target past the end of the binary.
IMAGE_END = 0x10000
IO_START, IO_END = 0xC000, 0xD000
ROM_BASE = 0xD000
OPERAND_SIZES = {"imp": 0, "acc": 0, "imm": 1, "zp": 1, "zpx": 1, "zpy": 1, "izx": 1, "izy": 1,
                 "rel": 1, "abs": 2, "abx": 2, "aby": 2, "ind": 2}
JMP_INDIRECT = 0x6C
WRITE_MNEMONICS = {"STA", "STX", "STY", "INC", "DEC", "ASL", "LSR", "ROL", "ROR"}
# Bytes an absolute write may reach: one, or base + index (0-255).
WRITE_RANGES = {"abs": 1, "abx": 256, "aby": 256}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def load_opcode_table() -> dict[int, tuple[str, str]]:
    analyze = Path(__file__).resolve().parent.parent / "10_analyze.py"
    spec = importlib.util.spec_from_file_location("analyze", analyze)
    module = importlib.util.module_from_spec(spec)
    sys.modules["analyze"] = module
    spec.loader.exec_module(module)
    return module.build_opcode_table()


def rewritten_instructions(image: dict[int, tuple[int, bool]], opcodes: dict[int, tuple[str, str]]) -> set[int]:
    """Instruction starts whose bytes some executed instruction writes to.

    apple2tc's own self-modification check misses some (e.g. STA $8BC8 into the
    operand of a JMP later in the same block), and compiled code would then
    use the stale operand. Starting a block at each such instruction moves the
    write into an earlier block, so the engine's byte check sees the change.
    Absolute and indexed-absolute writes only; pointer writes are not known
    until run time.
    """
    starts = sorted(addr for addr, (_, is_opcode) in image.items() if is_opcode)
    owner: dict[int, int] = {}
    for start in starts:
        owner[start] = start
        for offset in range(1, 3):
            entry = image.get(start + offset)
            if entry is None or entry[1]:
                break
            owner[start + offset] = start
    rewritten = set()
    for start in starts:
        mnemonic, mode = opcodes[image[start][0]]
        if mnemonic not in WRITE_MNEMONICS or mode not in WRITE_RANGES:
            continue
        low, high = image.get(start + 1), image.get(start + 2)
        if low is None or high is None:
            continue
        base = low[0] | (high[0] << 8)
        for target in range(base, min(base + WRITE_RANGES[mode], 0x10000)):
            if target in owner and owner[target] != start:
                rewritten.add(owner[target])
    return rewritten


def decode(addr: int, code: bytes, sizes: dict[int, int]) -> dict[int, bool] | None:
    """Map each byte address to True for an opcode, False for an operand."""
    kinds: dict[int, bool] = {}
    offset = 0
    while offset < len(code):
        size = sizes.get(code[offset])
        if size is None or offset + size > len(code):
            return None
        for i in range(size):
            kinds[addr + offset + i] = i == 0
        offset += size
    return kinds


def mid_instruction_segments(segments: dict[tuple[int, bytes], None], targets: set[int],
                             sizes: dict[int, int]) -> list[tuple[int, bytes]]:
    """Segments for branch targets that land inside another instruction.

    The run collector records straight runs from their first byte, so code
    entered part-way through an instruction (the BIT-skip trick: jumping into
    the operand of a BIT) is only seen as a target. Decoding from the target
    to the last whole instruction of the run gives that stream its own segment.
    """
    extra = []
    for addr, code in segments:
        kinds = decode(addr, code, sizes)
        if kinds is None:
            continue
        for target in range(addr + 1, addr + len(code)):
            if target not in targets or kinds[target]:
                continue
            offset, length = target - addr, 0
            while offset + length < len(code):
                size = sizes.get(code[offset + length])
                if size is None or offset + length + size > len(code):
                    break
                length += size
            if length:
                extra.append((target, code[offset:offset + length]))
    return extra


def usable(addr: int, code: bytes, rom: bytes) -> bool:
    end = addr + len(code)
    if addr < IMAGE_START or end > CODE_END or (addr < IO_END and end > IO_START):
        return False
    return not (addr >= ROM_BASE and rom[addr - ROM_BASE:end - ROM_BASE] == code)


def clashes(group: dict[int, tuple[int, bool]], addr: int, code: bytes, kinds: dict[int, bool]) -> bool:
    for i, value in enumerate(code):
        existing = group.get(addr + i)
        if existing and (existing[1] != kinds[addr + i] or (existing[1] and existing[0] != value)):
            return True
    return False


def main() -> None:
    if len(sys.argv) < 6:
        fail(__doc__.split("\n\n")[1])
    out_dir, rom = Path(sys.argv[1]), Path(sys.argv[2]).read_bytes()
    start_pc = int(next(line.split()[1] for line in Path(sys.argv[3]).read_text().splitlines()
                        if line.startswith("pc ")), 16)
    sites = {int(s, 16) for s in sys.argv[4].split(",") if s}
    opcode_table = load_opcode_table()
    sizes = {op: 1 + OPERAND_SIZES[mode] for op, (_, mode) in opcode_table.items()}

    segments: dict[tuple[int, bytes], None] = {}
    targets: set[int] = set(sites)
    branches: dict[int, set[int]] = {}
    base_stats = None
    for path in sys.argv[5:]:
        data = json.loads(Path(path).read_text())
        base_stats = base_stats or data["BaseStats"]
        targets.update(data["BranchTargets"])
        for origin, dests in data.get("Branches", {}).items():
            branches.setdefault(int(origin), set()).update(dests)
        for generation in data["generations"]:
            for segment in generation["code"]:
                segments[(segment["addr"], bytes(segment["bytes"]))] = None

    segments.update(dict.fromkeys(mid_instruction_segments(segments, targets, sizes)))

    groups: list[dict[int, tuple[int, bool]]] = []
    dropped = {"outside_or_rom": 0, "undecodable": 0}
    for addr, code in segments:
        if not usable(addr, code, rom):
            dropped["outside_or_rom"] += 1
            continue
        kinds = decode(addr, code, sizes)
        if kinds is None:
            dropped["undecodable"] += 1
            continue
        group = next((g for g in groups if not clashes(g, addr, code, kinds)), None)
        if group is None:
            group = {}
            groups.append(group)
        for i, value in enumerate(code):
            group.setdefault(addr + i, (value, kinds[addr + i]))

    out_dir.mkdir(parents=True, exist_ok=True)
    summary = {"segments": len(segments), "dropped": dropped, "groups": []}
    for index, own in enumerate(groups):
        image = dict(own)
        for other in groups:
            for addr, entry in other.items():
                image.setdefault(addr, entry)
        opcodes = {addr for addr, (_, is_opcode) in image.items() if is_opcode}
        binary = bytearray(IMAGE_END - IMAGE_START)
        for addr, (value, _) in image.items():
            binary[addr - IMAGE_START] = value
        header = bytes([IMAGE_START & 0xFF, IMAGE_START >> 8, len(binary) & 0xFF, len(binary) >> 8])
        (out_dir / f"g{index}.b33").write_bytes(header + binary)

        rewritten = rewritten_instructions(image, opcode_table)
        # a2n-t2 restarts the game when it reaches JMP ($FFFC); the check
        # runs between blocks, so the jump must start one.
        reboots = {a for a in opcodes if image[a][0] == JMP_INDIRECT
                   and image.get(a + 1, (0,))[0] == 0xFC and image.get(a + 2, (0,))[0] == 0xFF}
        group_targets = sorted(t for t in targets | rewritten | reboots if t in opcodes)
        group_branches = {str(o): sorted(d for d in dests if d in opcodes)
                          for o, dests in sorted(branches.items()) if o in opcodes}
        stats = dict(base_stats)
        stats["startRegs"] = dict(base_stats["startRegs"],
                                  pc=start_pc if start_pc in opcodes else group_targets[0])
        run_data = {"BaseStats": stats, "BranchTargets": group_targets,
                    "Branches": {o: d for o, d in group_branches.items() if d}, "generations": []}
        (out_dir / f"g{index}.json").write_text(json.dumps(run_data) + "\n")
        (out_dir / f"g{index}.opcodes.json").write_text(json.dumps(sorted(opcodes)) + "\n")
        summary["groups"].append({"name": f"g{index}", "own_bytes": len(own), "image_bytes": len(image),
                                  "targets": len(group_targets), "rewritten_splits": len(rewritten),
                                  "missing_sites": [f"${s:04X}" for s in sorted(sites - opcodes)]})
    (out_dir / "groups.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"{len(groups)} groups from {len(segments)} segments; dropped {dropped}")


if __name__ == "__main__":
    main()
