"""Unit tests for the boot judgement in tools/lib/compat_sweep.py. No emulator or disk images."""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools", "lib"))
import compat_sweep as sweep  # noqa: E402


def regs(pc: str, vidmode: str = "text") -> dict[str, str]:
    return {"pc": pc, "vidmode": vidmode}


class JudgeTests(unittest.TestCase):
    def test_graphics_counts_as_booted(self) -> None:
        self.assertTrue(sweep.judge(regs("6000", "hgr"), [], "", cmos=False).booted)

    def test_blank_graphics_page_is_not_booted(self) -> None:
        boot = sweep.judge(regs("0820", "hgr"), [], "", cmos=False, graphics_blank=True)
        self.assertEqual(boot.detail, sweep.BLANK_GRAPHICS)

    def test_graphics_page_blank_reads_the_displayed_page(self) -> None:
        memory = bytearray(0x10000)
        memory[0x4000] = 0x01
        state = {"pc": "0820", "vidmode": "hgr", "mixed": "0", "vidpage": "1"}
        self.assertTrue(sweep.graphics_page_blank(state, bytes(memory), None))
        self.assertFalse(sweep.graphics_page_blank({**state, "vidpage": "2"}, bytes(memory), None))
        memory[0x2000] = 0x80
        self.assertTrue(sweep.graphics_page_blank(state, bytes(memory), None))
        self.assertFalse(sweep.graphics_page_blank({**state, "mixed": "1"}, bytes(memory), None))

    def test_still_in_boot_rom_is_no_boot_sector(self) -> None:
        boot = sweep.judge(regs("C65C"), [], "", cmos=False)
        self.assertFalse(boot.booted)
        self.assertTrue(boot.no_boot_sector)

    def test_invalid_opcode_on_the_6502_fails(self) -> None:
        boot = sweep.judge(regs("6000", "hgr"), [], "Invalid instruction $DA\n", cmos=False)
        self.assertFalse(boot.booted)
        self.assertIn("$DA", boot.detail)

    def test_requirement_message_fails_only_on_the_ii_plus(self) -> None:
        rows = ["THIS PRODUCT REQUIRES AN APPLE //E WITH"]
        self.assertFalse(sweep.judge(regs("FD0C"), rows, "", cmos=False).booted)
        self.assertTrue(sweep.judge(regs("FD0C"), rows, "", cmos=True).booted)

    def test_error_text_fails(self) -> None:
        self.assertFalse(sweep.judge(regs("D000"), ["?SYNTAX ERROR IN 10", "]"], "", cmos=True).booted)

    def test_monitor_break_is_reported_as_a_crash(self) -> None:
        rows = ["B902-    A=D0 X=60 Y=F0 P=30 S=FB", "*"]
        self.assertEqual(sweep.judge(regs("FD1B"), rows, "", cmos=False).detail,
                         "crashed into the monitor at $B902")

    def test_bare_prompt_fails_and_menu_text_boots(self) -> None:
        self.assertFalse(sweep.judge(regs("FD1B"), ["]"], "", cmos=False).booted)
        self.assertTrue(sweep.judge(regs("FD1B"), ["MAIN MENU", "1. ADDITION"], "", cmos=False).booted)

    def test_blank_screen_is_marked_for_a_longer_retry(self) -> None:
        self.assertEqual(sweep.judge(regs("B8D3"), [], "", cmos=False).detail, sweep.BLANK_SCREEN)


class TextTests(unittest.TestCase):
    def test_eighty_columns_interleave_aux_first(self) -> None:
        main = bytearray(0xC000)
        aux = bytearray(0xC000)
        aux[0x400], main[0x400] = 0xC8, 0xC9  # "H", "I"
        self.assertEqual(sweep.text_rows(bytes(main), bytes(aux))[0][:2], "HI")


if __name__ == "__main__":
    unittest.main()
