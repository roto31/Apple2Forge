"""Print the 24 rows of Apple II text page 1 ($0400-$07FF) from a 64K RAM snapshot.

Usage: python3 -I tests/tools/text_page.py SNAPSHOT
Output: one line per row, "NN|text" (trailing spaces trimmed). Exit 2 on bad input.
"""
import sys

TEXT_PAGE_1 = 0x0400
ROWS = 24
COLUMNS = 40
RAM_SIZE = 0x10000


def row_address(row: int) -> int:
    """Apple II text rows are interleaved: three groups of eight, 0x80 apart."""
    return TEXT_PAGE_1 + (row % 8) * 0x80 + (row // 8) * COLUMNS


def screen_char(byte: int) -> str:
    code = byte & 0x7F
    if code < 0x20:
        code += 0x40  # inverse/flashing letters are stored as $00-$1F
    return chr(code) if 0x20 <= code < 0x7F else " "


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(sys.argv[1], "rb") as snapshot_file:
        ram = snapshot_file.read()
    if len(ram) != RAM_SIZE:
        print(f"ERROR: {sys.argv[1]} is {len(ram)} bytes, expected {RAM_SIZE}", file=sys.stderr)
        return 2
    for row in range(ROWS):
        start = row_address(row)
        text = "".join(screen_char(b) for b in ram[start:start + COLUMNS]).rstrip()
        print(f"{row:02d}|{text}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
