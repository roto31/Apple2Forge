#!/usr/bin/env python3
"""Unit tests for tools/10_analyze.py using synthetic disk images only.

Run: python3 -I tests/test_10_analyze.py
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType

REPO_ROOT = Path(__file__).resolve().parent.parent


def load_analyzer() -> ModuleType:
    spec = importlib.util.spec_from_file_location("analyzer", REPO_ROOT / "tools" / "10_analyze.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["analyzer"] = module
    spec.loader.exec_module(module)
    return module


analyzer = load_analyzer()


def sector_offset(track: int, sector: int) -> int:
    return (track * analyzer.SECTORS_PER_TRACK + sector) * analyzer.SECTOR_SIZE


def high_ascii(text: str, width: int) -> bytes:
    return bytes(ord(character) | 0x80 for character in text.ljust(width))


def build_dos33_image(boot_code: bytes) -> bytes:
    """DOS-order image: VTOC, one catalog sector holding HELLO, one T/S list."""
    image = bytearray(analyzer.SECTOR_IMAGE_SIZE)
    image[0:len(boot_code)] = boot_code
    vtoc = sector_offset(17, 0)
    image[vtoc + 1:vtoc + 4] = bytes([17, 15, 3])
    image[vtoc + 6] = 254
    image[vtoc + 0x27] = 122
    image[vtoc + 0x34:vtoc + 0x38] = bytes([35, 16, 0x00, 0x01])
    for track in range(analyzer.TRACK_COUNT):
        if track not in (0, 17):
            image[vtoc + 0x38 + track * 4:vtoc + 0x38 + track * 4 + 2] = b"\xFF\xFF"
    catalog = sector_offset(17, 15)
    entry = catalog + 0x0B
    image[entry:entry + 3] = bytes([17, 14, 0x02])
    image[entry + 3:entry + 33] = high_ascii("HELLO", 30)
    image[entry + 33:entry + 35] = bytes([2, 0])
    ts_list = sector_offset(17, 14)
    image[ts_list + 0x0C:ts_list + 0x0E] = bytes([17, 13])
    image[sector_offset(17, 13)] = 0x01
    return bytes(image)


def build_prodos_order_image() -> bytes:
    """ProDOS-order image with a volume directory at block 2 holding one file."""
    image = bytearray(analyzer.SECTOR_IMAGE_SIZE)
    block = 2 * analyzer.BLOCK_SIZE
    image[block + 4] = 0xF0 | 4
    image[block + 5:block + 9] = b"TEST"
    image[block + 0x23] = 0x27
    image[block + 0x24] = 0x0D
    image[block + 0x27] = 6
    image[block + 0x29:block + 0x2B] = (280).to_bytes(2, "little")
    entry = block + 4 + 0x27
    image[entry] = 0x10 | 5
    image[entry + 1:entry + 6] = b"HELLO"
    image[entry + 0x10] = 0xFC
    image[entry + 0x13] = 1
    bitmap = 6 * analyzer.BLOCK_SIZE
    image[bitmap:bitmap + 35] = b"\x00" + b"\xFF" * 34
    return bytes(image)


class AnalyzerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.folder = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def analyze_bytes(self, name: str, data: bytes) -> dict:
        path = self.folder / name
        path.write_bytes(data)
        analysis = analyzer.analyze(path)
        analyzer.write_outputs(analysis, self.folder / "out")
        json.loads((self.folder / "out" / "analysis.json").read_text())
        self.assertTrue((self.folder / "out" / "analysis.md").read_text())
        return analysis

    def test_standard_dos33_disk(self) -> None:
        """A DOS 3.3 boot sector and catalog read as a standard disk."""
        dos33_boot = bytes.fromhex("01A527C909") + b"\x00"
        analysis = self.analyze_bytes("standard.dsk", build_dos33_image(dos33_boot))
        self.assertEqual(analysis["format"]["sector_order"], "dos")
        self.assertEqual(analysis["filesystem"]["type"], "dos33")
        self.assertEqual([entry["name"] for entry in analysis["filesystem"]["catalog"]], ["HELLO"])
        self.assertEqual(analysis["boot"]["loader"]["id"], "dos33")
        self.assertFalse(analysis["boot"]["loader"]["custom"])
        self.assertEqual(analysis["boot"]["entry_point_status"], "not-applicable")

    def test_custom_loader_entry_point(self) -> None:
        """Static tracing finds the single jump out of a custom boot sector."""
        custom_boot = bytes.fromhex("01 4C0508 00 2093FE 2C81C0 4C0040".replace(" ", ""))
        analysis = self.analyze_bytes("custom.dsk", build_dos33_image(custom_boot))
        boot = analysis["boot"]
        self.assertTrue(boot["loader"]["custom"])
        self.assertEqual(boot["loader"]["id"], "unknown-custom")
        self.assertEqual(boot["entry_point"], "$4000")
        self.assertIn("Monitor ROM SETVID", [call["kind"] for call in boot["external_calls"]])
        self.assertEqual([row["text"] for row in boot["disassembly"]][:2], ["JMP $0805", "JSR $FE93"])
        self.assertEqual(boot["soft_switches"][0]["instruction"], "BIT $C081")

    def test_prodos_order_image(self) -> None:
        """A .po file is read in ProDOS order and its volume directory listed."""
        analysis = self.analyze_bytes("volume.po", build_prodos_order_image())
        self.assertEqual(analysis["format"]["sector_order"], "prodos")
        self.assertFalse(analysis["format"]["apple2tc_readable"])
        self.assertEqual(analysis["filesystem"]["type"], "prodos")
        self.assertEqual(analysis["filesystem"]["catalog"][0]["name"], "HELLO")
        self.assertEqual(analysis["filesystem"]["free_blocks"], 272)

    def test_nib_sized_input_is_unsupported(self) -> None:
        """A .nib-sized file is reported unsupported, even with a .dsk extension."""
        analysis = self.analyze_bytes("mislabeled.dsk", bytes(analyzer.NIB_IMAGE_SIZE))
        self.assertEqual(analysis["format"]["status"], "unsupported")
        self.assertEqual(analysis["format"]["kind"], "nib")
        self.assertTrue(analysis["format"]["notes"])
        self.assertFalse(analysis["summary"]["supported"])

    def test_truncated_input_is_unsupported(self) -> None:
        """A wrong-size file is reported unsupported without crashing."""
        analysis = self.analyze_bytes("short.dsk", bytes(1000))
        self.assertEqual(analysis["format"]["status"], "unsupported")
        self.assertIn("Unsupported", analysis["summary"]["headline"])

    def test_marker_sequence_verdicts(self) -> None:
        """Standard RWTS prologues pass; a swapped prologue is flagged."""
        self.assertEqual(analyzer.classify_marker_sequence((0xD5, 0xAA, 0x96)), "standard")
        self.assertEqual(analyzer.classify_marker_sequence((0xAA, 0xD5, 0xAD)), "non-standard")
        self.assertEqual(analyzer.classify_marker_sequence((0xDE,)), "too-short-to-judge")


if __name__ == "__main__":
    unittest.main(verbosity=2)
