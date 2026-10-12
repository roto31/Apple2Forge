#!/usr/bin/env python3
"""Check that a file holds no Apple II ROM and no Disk II boot PROM bytes.

Usage: t2_romscan.py FILE ROM DISK2_SOURCE

Looks for every 16-byte window (at a 4-byte stride) of the 12K Apple ][+ ROM
and of the 256-byte P5 PROM table in DISK2_SOURCE (vendor a2io disk2.c).
Windows with fewer than 6 distinct bytes (fills, short runs) are skipped:
they match ordinary code and data by chance. Exits 1 if any window is found.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from t2_image import read_prom  # noqa: E402

WINDOW = 16
STRIDE = 4
MIN_DISTINCT = 6


def found_windows(source: bytes, haystack: bytes) -> int:
    return sum(1 for i in range(0, len(source) - WINDOW + 1, STRIDE)
               if len(set(source[i:i + WINDOW])) >= MIN_DISTINCT and source[i:i + WINDOW] in haystack)


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    haystack = Path(sys.argv[1]).read_bytes()
    rom_hits = found_windows(Path(sys.argv[2]).read_bytes(), haystack)
    prom_hits = found_windows(read_prom(Path(sys.argv[3])), haystack)
    print(f"{sys.argv[1]}: {rom_hits} Apple II ROM windows, {prom_hits} Disk II PROM windows")
    return 0 if rom_hits == prom_hits == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
