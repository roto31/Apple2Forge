"""Unit tests for tools/lib/t1_disk_set.py."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.join(os.path.dirname(__file__), "..")
TOOL = os.path.join(REPO, "tools", "lib", "t1_disk_set.py")
sys.path.insert(0, os.path.join(REPO, "tools", "lib"))
import t1_disk_set  # noqa: E402


def run_tool(*args: str) -> tuple[int, str, str]:
    result = subprocess.run(
        [sys.executable, "-I", TOOL, *args],
        capture_output=True,
        text=True,
        cwd=REPO,
    )
    return result.returncode, result.stdout, result.stderr


class DiskSetTests(unittest.TestCase):
    def test_side_ab_order_and_labels(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            a = os.path.join(folder, "Quest side B.dsk")
            b = os.path.join(folder, "Quest side A.dsk")
            for path in (a, b):
                with open(path, "wb") as handle:
                    handle.write(b"\x00" * 100)
            record = t1_disk_set.disk_set_record([t1_disk_set.parse_disk_file(a), t1_disk_set.parse_disk_file(b)])
            labels = [s["label"] for s in record["sides"]]
            self.assertEqual(labels, ["Disk 1 Side A", "Disk 1 Side B"])
            self.assertEqual(record["sides"][0]["bundleFile"], "disk.dsk")
            self.assertEqual(record["sides"][1]["bundleFile"], "side-02.dsk")
            self.assertEqual(record["sides"][0]["startupDrive"], "1")
            self.assertEqual(record["sides"][1]["startupDrive"], "2")

    def test_two_disks_four_sides(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            names = [
                "Game disk 2 side B.dsk",
                "Game disk 1 side A.dsk",
                "Game disk 1 side B.dsk",
                "Game disk 2 side A.dsk",
            ]
            images = []
            for name in names:
                path = os.path.join(folder, name)
                with open(path, "wb") as handle:
                    handle.write(b"\x00")
                images.append(t1_disk_set.parse_disk_file(path))
            record = t1_disk_set.disk_set_record(images)
        self.assertEqual(len(record["sides"]), 4)
        self.assertEqual(record["sides"][2]["bundleFile"], "side-03.dsk")

    def test_one_of_three_unlabeled_boot(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            paths = []
            for name in ("Solo.dsk",):
                path = os.path.join(folder, name)
                with open(path, "wb") as handle:
                    handle.write(b"\x00")
                paths.append(path)
            record = t1_disk_set.disk_set_record([t1_disk_set.parse_disk_file(paths[0])])
            self.assertEqual(record["title"], "Solo")
            self.assertEqual(len(record["sides"]), 1)

    def test_collision_exits_two(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            a = os.path.join(folder, "Game side A.dsk")
            b = os.path.join(folder, "Game disk 1 side A.dsk")
            for path in (a, b):
                with open(path, "wb") as handle:
                    handle.write(b"\x00")
            code, _, stderr = run_tool(a, b)
            self.assertEqual(code, 2)
            self.assertIn("disk 1 side A", stderr)

    def test_group_two_titles(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            paths = []
            for name in ("Alpha side A.dsk", "Beta side A.dsk"):
                path = os.path.join(folder, name)
                with open(path, "wb") as handle:
                    handle.write(b"\x00")
                paths.append(path)
            code, stdout, _ = run_tool("--group", *paths)
            self.assertEqual(code, 0)
            groups = json.loads(stdout)
            self.assertEqual(len(groups), 2)
            titles = sorted(g["title"] for g in groups)
            self.assertEqual(titles, ["Alpha", "Beta"])


if __name__ == "__main__":
    unittest.main()
