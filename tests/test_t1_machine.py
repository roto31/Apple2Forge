"""Unit tests for tools/lib/t1_machine.classify_boot wiring."""
from __future__ import annotations

import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools", "lib"))
import compat_sweep  # noqa: E402
import t1_machine  # noqa: E402


class MachineClassifyTests(unittest.TestCase):
    def test_iiplus_when_plus_boots_and_no_hint(self) -> None:
        args = mock.Mock(emulator="/bin/true", rom_dir="/roms", frames=60)
        boot = compat_sweep.Boot(True, "ok", no_boot_sector=False)
        with mock.patch.object(compat_sweep, "run_boot", return_value=boot):
            result = compat_sweep.classify_boot(args, "Number Munchers", "/a.dsk", None)
        self.assertEqual(result["requirement"], compat_sweep.REQUIREMENT_IIPLUS)

    def test_iie_when_only_iie_boots(self) -> None:
        args = mock.Mock(emulator="/bin/true", rom_dir="/roms", frames=60)
        plus = compat_sweep.Boot(False, "no", no_boot_sector=False)
        iie = compat_sweep.Boot(True, "ok", no_boot_sector=False)

        def side_effect(_args, model, _d1, _d2):
            return plus if model == "iiplus" else iie

        with mock.patch.object(compat_sweep, "run_boot", side_effect=side_effect):
            result = compat_sweep.classify_boot(args, "Game", "/a.dsk", None)
        self.assertEqual(result["requirement"], compat_sweep.REQUIREMENT_IIE)

    def test_explicit_model_skips_boot(self) -> None:
        with mock.patch.object(compat_sweep, "run_boot") as run_boot:
            code = t1_machine.main(["--emulator", "/bin/true", "--rom-dir", "/roms", "--model", "iie", "/a.dsk"])
        run_boot.assert_not_called()
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
