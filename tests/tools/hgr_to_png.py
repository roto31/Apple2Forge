"""Render an Apple II hi-res page from a RAM dump to a monochrome PNG.

Usage: python3 -I tests/tools/hgr_to_png.py SNAPSHOT PAGE OUT.png [SCALE]
  SNAPSHOT  a 64K RAM image, or an 8K dump of just the page
  PAGE  1 ($2000-$3FFF) or 2 ($4000-$5FFF)
  SCALE integer pixel scale, default 3 (OCR reads larger glyphs more reliably)
Monochrome (lit bit = white) is enough for text recognition; colour fringes
are deliberately ignored. Exit 2 on bad input.
"""
import os
import struct
import sys
import zlib

RAM_SIZE = 0x10000
PAGE_SIZE = 0x2000
PAGE_BASES = {1: 0x2000, 2: 0x4000}
WIDTH = 280
HEIGHT = 192
PIXELS_PER_BYTE = 7
WHITE = 0xFF
BLACK = 0x00
DEFAULT_SCALE = 3


def row_address(page_base: int, y: int) -> int:
    """Hi-res rows are interleaved in three levels: 8 x 8 x 3."""
    return page_base + (y % 8) * 0x400 + ((y // 8) % 8) * 0x80 + (y // 64) * 0x28


def render_rows(ram: bytes, page_base: int) -> list[bytes]:
    rows = []
    for y in range(HEIGHT):
        start = row_address(page_base, y)
        pixels = bytearray()
        for byte in ram[start:start + WIDTH // PIXELS_PER_BYTE]:
            for bit in range(PIXELS_PER_BYTE):
                pixels.append(WHITE if byte & (1 << bit) else BLACK)
        rows.append(bytes(pixels))
    return rows


def scale_rows(rows: list[bytes], scale: int) -> list[bytes]:
    scaled = []
    for row in rows:
        wide = bytes(value for value in row for _ in range(scale))
        scaled.extend([wide] * scale)
    return scaled


def write_grayscale_png(path: str, rows: list[bytes]) -> None:
    height, width = len(rows), len(rows[0])

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)  # 8-bit grayscale
    raw = b"".join(b"\x00" + row for row in rows)  # filter type 0 per row
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path + ".tmp", "wb") as out_file:
        out_file.write(png)
    os.replace(path + ".tmp", path)


def main() -> int:
    if len(sys.argv) not in (4, 5):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    snapshot_path, page_text, out_path = sys.argv[1:4]
    scale = int(sys.argv[4]) if len(sys.argv) == 5 else DEFAULT_SCALE
    if page_text not in ("1", "2") or scale < 1:
        print("ERROR: PAGE must be 1 or 2 and SCALE >= 1", file=sys.stderr)
        return 2
    with open(snapshot_path, "rb") as snapshot_file:
        ram = snapshot_file.read()
    if len(ram) == PAGE_SIZE:
        page_base = 0
    elif len(ram) == RAM_SIZE:
        page_base = PAGE_BASES[int(page_text)]
    else:
        print(f"ERROR: {snapshot_path} is {len(ram)} bytes, expected {RAM_SIZE} or {PAGE_SIZE}", file=sys.stderr)
        return 2
    rows = render_rows(ram, page_base)
    write_grayscale_png(out_path, scale_rows(rows, scale))
    return 0


if __name__ == "__main__":
    sys.exit(main())
