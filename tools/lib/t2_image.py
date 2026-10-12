"""Build the T2 start image: a snapshot with every ROM-derived byte removed.

Usage: python3 -I tools/lib/t2_image.py SNAPSHOT ROM OUT_PREFIX [DISK2_PROM_SOURCE]
       SNAPSHOT: a --snapshot-out= capture (SNAPSHOT, .regs, .lc, .disk).
       ROM: the user's 12K Apple II ROM, used only to find and remove its bytes.
       OUT_PREFIX: writes OUT_PREFIX, .regs, .lc, .disk, .json and .blanked
       (the blanked blocks that were identical to the ROM, as "AREA HHHH"
       lines; a2n-t2 --rom= refills them from the user's own ROM).
       DISK2_PROM_SOURCE: optional C file holding the Disk II boot PROM table, so
       its 256 bytes are checked for too.

A capture taken after boot still holds ROM bytes: the Monitor copied into
Language Card RAM ($F800-$FFFF), Applesoft blocks the card bank never
overwrote, and the Disk II boot PROM the emulator keeps at $C600. The T2 build
must ship none of them, so this blanks:
  - $C000-$CFFF in the RAM image (IO space; the CPU only reads RAM there to
    fetch boot code, and T2 never boots);
  - $F800-$FFFF wherever card RAM holds it (T2 runs the few Monitor routines the
    game calls as C, see t2/runtime/a2n_monitor.cpp);
  - every other 256-byte block of $D000-$F7FF identical to the ROM at the same
    address.
Then it checks every aligned 256-byte block of RAM and card RAM against all 48
ROM blocks and the boot PROM, and exits 1 if any remain.
"""
from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path

BLOCK = 0x100
ROM_BASE = 0xD000
ROM_SIZE = 0x3000
IO_START, IO_END = 0xC000, 0xD000
MONITOR_START = 0xF800
LC_HEADER = 8
LC_BANK = 0x1000
LC_HIGH = 0x2000
LC_BYTES = LC_HEADER + 2 * LC_BANK + LC_HIGH
LC_READ_RAM = 0x01
LC_BANK2 = 0x02
MIN_DISTINCT_BYTES = 4


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def read_prom(source: Path) -> bytes:
    table = re.search(r"disk2_boot_rom\[256\]\s*=\s*\{(.*?)\};", source.read_text(), re.S)
    if not table:
        fail(f"{source}: no disk2_boot_rom[256] table")
    values = bytes(int(v, 16) for v in re.findall(r"0x([0-9A-Fa-f]{2})", table.group(1)))
    if len(values) != BLOCK:
        fail(f"{source}: disk2_boot_rom has {len(values)} bytes, expected 256")
    return values


def blank_rom_blocks(memory: bytearray, base: int, rom: bytes) -> list[tuple[int, bool]]:
    """Blank blocks of `memory` (mapped at `base`) that are ROM, or Monitor.

    Returns (address, was identical to the ROM) per blanked block."""
    blanked = []
    for offset in range(0, len(memory), BLOCK):
        addr = base + offset
        rom_block = rom[addr - ROM_BASE:addr - ROM_BASE + BLOCK]
        identical = memory[offset:offset + BLOCK] == rom_block
        if addr >= MONITOR_START or identical:
            memory[offset:offset + BLOCK] = bytes(BLOCK)
            blanked.append((addr, identical))
    return blanked


def forbidden_blocks(rom: bytes, prom: bytes | None) -> dict[bytes, str]:
    blocks = {rom[i:i + BLOCK]: f"ROM ${ROM_BASE + i:04X}" for i in range(0, ROM_SIZE, BLOCK)}
    if prom:
        blocks[prom] = "Disk II boot PROM"
    return {b: name for b, name in blocks.items() if len(set(b)) >= MIN_DISTINCT_BYTES}


def find_forbidden(memory: bytes, label: str, forbidden: dict[bytes, str]) -> list[str]:
    blocks = [(i, bytes(memory[i:i + BLOCK])) for i in range(0, len(memory) - BLOCK + 1, BLOCK)]
    return [f"{label}+${i:04X} = {forbidden[block]}" for i, block in blocks if block in forbidden]


def main() -> None:
    if len(sys.argv) not in (4, 5):
        fail(__doc__.split("\n\n")[1])
    snapshot, rom_path, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    prom = read_prom(Path(sys.argv[4])) if len(sys.argv) == 5 else None
    rom = rom_path.read_bytes()
    if len(rom) != ROM_SIZE:
        fail(f"{rom_path}: {len(rom)} bytes, expected a 12K Apple II ROM")
    ram = bytearray(snapshot.read_bytes())
    lc = bytearray(Path(f"{snapshot}.lc").read_bytes())
    if len(ram) != 0x10000 or len(lc) != LC_BYTES or lc[:4] != b"A2LC":
        fail(f"{snapshot}: not a 64K snapshot with a Language Card sidecar")

    ram[IO_START:IO_END] = bytes(IO_END - IO_START)
    bank1 = bytearray(lc[LC_HEADER:LC_HEADER + LC_BANK])
    bank2 = bytearray(lc[LC_HEADER + LC_BANK:LC_HEADER + 2 * LC_BANK])
    high = bytearray(lc[LC_HEADER + 2 * LC_BANK:])
    upper = bytearray(ram[ROM_BASE:])
    blanked_by_area = {
        "ram": blank_rom_blocks(upper, ROM_BASE, rom),
        "lc_bank1": blank_rom_blocks(bank1, ROM_BASE, rom),
        "lc_bank2": blank_rom_blocks(bank2, ROM_BASE, rom),
        "lc_high": blank_rom_blocks(high, 0xE000, rom),
    }
    blanked = {("ram_D000_FFFF" if area == "ram" else area): [f"${addr:04X}" for addr, _ in blocks]
               for area, blocks in blanked_by_area.items()}
    # Blocks the user's own ROM can put back exactly (a2n-t2 --rom=).
    refill = [f"{area} {addr:04X}" for area, blocks in blanked_by_area.items()
              for addr, identical in blocks if identical]
    ram[ROM_BASE:] = upper
    lc[LC_HEADER:] = bank1 + bank2 + high

    forbidden = forbidden_blocks(rom, prom)
    remaining = (find_forbidden(ram, "ram", forbidden) + find_forbidden(bank1, "bank1", forbidden)
                 + find_forbidden(bank2, "bank2", forbidden) + find_forbidden(high, "high", forbidden))

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(ram)
    Path(f"{out}.lc").write_bytes(lc)
    for suffix in (".regs", ".disk"):
        shutil.copyfile(f"{snapshot}{suffix}", f"{out}{suffix}")
    Path(f"{out}.blanked").write_text("".join(line + "\n" for line in refill))
    report = {"snapshot": str(snapshot), "blanked_io": "$C000-$CFFF", "blanked_blocks": blanked,
              "refillable_from_user_rom": len(refill),
              "lc_flags": lc[5], "checked_blocks": len(forbidden),
              "prom_checked": prom is not None, "rom_blocks_remaining": remaining}
    Path(f"{out}.json").write_text(json.dumps(report, indent=2) + "\n")
    count = sum(len(v) for v in blanked.values())
    print(f"blanked IO page and {count} ROM/Monitor blocks; {len(remaining)} ROM blocks remain")
    if remaining:
        fail("ROM bytes remain in the start image: " + ", ".join(remaining[:8]))


if __name__ == "__main__":
    main()
