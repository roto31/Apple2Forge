"""Turn apple2tc --simple-c output for each overlay group into T2 block code.

Usage: python3 -I tools/lib/t2_link.py GROUPS_DIR OUT_DIR
       GROUPS_DIR: t2_groups.py output plus gN.c from apple2tc --simple-c.
       OUT_DIR: receives t2_gN.c, t2_blocks.c and t2_link.json.

apple2tc emits one `case` per basic block inside a run_emulated() loop. Here
each group's cases become one function, t2_run_gN(), that runs the single block
at s_pc. The engine (t2/runtime/a2n_engine.cpp) only calls it after checking
that memory holds the bytes the block was compiled from, so t2_blocks.c lists
every block with those bytes and a mask: operands apple2tc found to be
self-modified are read from memory at run time, so they are left out of the
check.

Each block's CYCLES() charge is replaced by a per-instruction T2_I(), so IO
sees the same cycle count the interpreter gives it, and the engine can stop at
the same instruction the interpreter would at the end of a frame.

Kept: blocks whose every instruction start was executed in that group's
sessions, below $F800 and outside $C000-$CFFF, with no BRK or invalid opcode.
A block identical to one an earlier group already has is not repeated. Also
left to the interpreter: blocks with a line apple2tc truncated (its simple-C
operand buffer is 32 bytes, too short for a self-modified indirect operand;
truncation always drops closing parentheses, so it shows as an imbalance).
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

IMAGE_START = 0x0100
CODE_END = 0xF800
IO_START, IO_END = 0xC000, 0xD000
CASE_HEADER = re.compile(r"^    case 0x([0-9a-f]{4}): // \[\$([0-9A-F]{4})\.\.\$([0-9A-F]{4,5})\]")
INSTRUCTION = re.compile(r"/\* \$([0-9A-F]{4}) (\S+) \*/")
CYCLES_LINE = re.compile(r"^\s*CYCLES\(0x[0-9a-f]{4}, \d+\);\n", re.M)
OPERAND_SMC = "// WARNING: operand self modification."
REJECTED_MNEMONICS = {"BRK", "???"}
MASK_CHECK, MASK_SKIP = 0xFF, 0x00


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def split_cases(source: str, path: Path) -> list[str]:
    try:
        body = source.split("    switch (s_pc) {\n", 1)[1].split("    default:\n", 1)[0]
    except IndexError:
        fail(f"{path}: not apple2tc --simple-c output")
    chunks = re.split(r"(?m)^(?=    case 0x)", body)
    return [c for c in chunks if c.startswith("    case 0x")]


def block_mask(chunk: str, start: int, length: int) -> bytes:
    """Check every byte except the operands of self-modified instructions."""
    starts: list[int] = []
    self_modified: set[int] = set()
    pending = False
    for line in chunk.splitlines():
        if OPERAND_SMC in line:
            pending = True
        match = INSTRUCTION.search(line)
        if match:
            starts.append(int(match.group(1), 16))
            if pending:
                self_modified.add(starts[-1])
            pending = False
    mask = bytearray([MASK_CHECK] * length)
    for index, addr in enumerate(starts):
        if addr in self_modified:
            end = starts[index + 1] if index + 1 < len(starts) else start + length
            mask[addr + 1 - start:end - start] = bytes([MASK_SKIP] * (end - addr - 1))
    return bytes(mask)


def main() -> None:
    if len(sys.argv) != 3:
        fail(__doc__.split("\n\n")[1])
    groups_dir, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    names = sorted((p.stem for p in groups_dir.glob("g*.c")), key=lambda n: int(n[1:]))
    if not names:
        fail(f"{groups_dir}: no gN.c files")
    out_dir.mkdir(parents=True, exist_ok=True)

    seen: set[tuple[int, bytes, bytes]] = set()
    table: list[tuple[int, int, int, bytes, bytes]] = []
    stats = {"groups": {}}
    # Instruction starts executed in any overlay. A block that runs from one
    # segment into a neighbouring one (e.g. past a BIT-skip) can take those
    # bytes from another group's image; the run-time byte check still makes
    # sure a block only runs when RAM holds exactly the bytes it was built from.
    executed: set[int] = set()
    for name in names:
        executed.update(json.loads((groups_dir / f"{name}.opcodes.json").read_text()))
    for group_index, name in enumerate(names):
        image = (groups_dir / f"{name}.b33").read_bytes()[4:]
        cases = split_cases((groups_dir / f"{name}.c").read_text(), groups_dir / f"{name}.c")
        kept: list[str] = []
        rejected = {"not_executed": 0, "outside": 0, "brk_or_invalid": 0,
                    "truncated_by_apple2tc": 0, "duplicate": 0}
        for chunk in cases:
            header = CASE_HEADER.match(chunk)
            if not header:
                fail(f"{name}: unparsed case header: {chunk.splitlines()[0]}")
            start, end = int(header.group(2), 16), int(header.group(3), 16)
            length = end - start + 1
            instructions = INSTRUCTION.findall(chunk)
            if start < IMAGE_START or end >= CODE_END or (start < IO_END and end >= IO_START):
                rejected["outside"] += 1
                continue
            if any(m in REJECTED_MNEMONICS for _, m in instructions):
                rejected["brk_or_invalid"] += 1
                continue
            if any(int(a, 16) not in executed for a, _ in instructions):
                rejected["not_executed"] += 1
                continue
            if any(line.count("(") != line.count(")") for line in chunk.splitlines()):
                rejected["truncated_by_apple2tc"] += 1
                continue
            code = image[start - IMAGE_START:end + 1 - IMAGE_START]
            mask = block_mask(chunk, start, length)
            masked = bytes(c & m for c, m in zip(code, mask))
            if (start, masked, mask) in seen:
                rejected["duplicate"] += 1
                continue
            seen.add((start, masked, mask))
            table.append((start, length, group_index, masked, mask))
            body = CYCLES_LINE.sub("", chunk)
            body = INSTRUCTION.sub(lambda m: f"T2_I(0x{m.group(1)}); {m.group(0)}", body)
            kept.append(body)
        lines = ['#include "a2n_block.h"', "", f"void t2_run_{name}(void) {{",
                 "  bool branchTarget = false;", "  uint16_t tmp16;", "  uint8_t tmp;",
                 "  (void)branchTarget;", "  (void)tmp16;", "  (void)tmp;", "  switch (s_pc) {"]
        lines += [chunk.rstrip("\n") for chunk in kept]
        lines += ["    default:", "      t2_unknown_block(s_pc);", "  }", "}", ""]
        (out_dir / f"t2_{name}.c").write_text("\n".join(lines))
        stats["groups"][name] = {"cases": len(cases), "kept": len(kept), "rejected": rejected}

    table.sort(key=lambda row: (row[0], row[2]))
    pool = bytearray()
    masks = bytearray()
    rows = []
    for start, length, group, masked, mask in table:
        rows.append(f"  {{0x{start:04X}, {length}, {group}, {len(pool)}}},")
        pool += masked
        masks += mask
    def c_bytes(data: bytes) -> str:
        return "\n".join("  " + ", ".join(f"0x{b:02X}" for b in data[i:i + 16]) + ","
                         for i in range(0, len(data), 16))
    blocks_c = ['#include "a2n_block.h"', ""]
    blocks_c += [f"void t2_run_{n}(void);" for n in names]
    blocks_c += ["", f"void (*const t2_group_runs[{len(names)}])(void) = {{"]
    blocks_c += [f"  t2_run_{n}," for n in names] + ["};", f"const unsigned t2_group_count = {len(names)};", ""]
    blocks_c += [f"const t2_block_t t2_blocks[{len(rows)}] = {{"] + rows + ["};"]
    blocks_c += [f"const unsigned t2_block_count = {len(rows)};", ""]
    blocks_c += [f"const uint8_t t2_block_bytes[{len(pool)}] = {{", c_bytes(bytes(pool)), "};"]
    blocks_c += [f"const uint8_t t2_block_masks[{len(masks)}] = {{", c_bytes(bytes(masks)), "};", ""]
    (out_dir / "t2_blocks.c").write_text("\n".join(blocks_c))
    stats.update(blocks=len(rows), code_bytes=len(pool),
                 smc_operand_bytes=sum(1 for m in masks if m == MASK_SKIP))
    (out_dir / "t2_link.json").write_text(json.dumps(stats, indent=2) + "\n")
    print(f"{len(rows)} blocks, {len(pool)} code bytes across {len(names)} groups")


if __name__ == "__main__":
    main()
