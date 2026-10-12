"""Unit tests for tools/lib/library_catalog.py. Made-up file names only; no disk images."""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools", "lib"))
import library_catalog as catalog  # noqa: E402

RULES_DIR = os.path.join(os.path.dirname(__file__), "..", "library")


def write_json(path: str, value: object) -> None:
    with open(path, "w") as handle:
        json.dump(value, handle)


def positions(title: catalog.Title) -> list[tuple[int, str, str]]:
    return [(i.disk, catalog.SIDE_NAMES[i.side], i.path) for i in title.images]


def group(paths: list[str]) -> list[catalog.Title]:
    return catalog.group_images([catalog.parse_image(p, "0" * 64) for p in paths])


class ParseTests(unittest.TestCase):
    def test_side_letters_and_numbers(self) -> None:
        for name, disk, side in [("Game side A.dsk", 1, 0), ("Game Side B.dsk", 1, 1),
                                 ("Game side 1.dsk", 1, 0), ("Game side 2.dsk", 1, 1),
                                 ("Game-SideB.dsk", 1, 1), ("Game side_c.dsk", 2, 0),
                                 ("Game side D.dsk", 2, 1)]:
            image = catalog.parse_image(name, "")
            self.assertEqual((image.title, image.disk, image.side), ("Game", disk, side), name)

    def test_disk_numbers_letters_and_combinations(self) -> None:
        for name, disk, side in [("Game disk 2.dsk", 2, 0), ("Game disk 1b.dsk", 1, 1),
                                 ("Game disk B.dsk", 2, 0), ("Game disk 2 of 3.dsk", 2, 0),
                                 ("Game disk 2 side B.dsk", 2, 1), ("Game 2 of 2.dsk", 2, 0)]:
            image = catalog.parse_image(name, "")
            self.assertEqual((image.title, image.disk, image.side), ("Game", disk, side), name)

    def test_unlabeled_is_disk_one_side_a(self) -> None:
        image = catalog.parse_image("folder/Plain Title (1984-Publisher).dsk", "")
        self.assertEqual((image.title, image.disk, image.side, image.explicit), ("Plain Title", 1, 0, False))
        self.assertEqual(image.notes, ["1984-Publisher"])
        self.assertEqual(image.folder, "folder")

    def test_issue_numbers_stay_in_title(self) -> None:
        image = catalog.parse_image("Magazine disk 74 side A.dsk", "")
        self.assertEqual((image.title, image.disk, image.side), ("Magazine disk 74", 1, 0))

    def test_words_containing_side_are_not_sides(self) -> None:
        image = catalog.parse_image("Inside Bodies.dsk", "")
        self.assertEqual((image.title, image.explicit), ("Inside Bodies", False))

    def test_program_disk_suffix_removed(self) -> None:
        self.assertEqual(catalog.parse_image("Tutor program disk.dsk", "").title, "Tutor")

    def test_iie_hint(self) -> None:
        titles = group(["Algebra (1989-Pub-128K) disk 1.dsk", "Algebra (1989-Pub-128K) disk 2.dsk"])
        self.assertEqual(catalog.requirement_hint(titles[0]), catalog.REQUIREMENT_IIE)


class GroupingTests(unittest.TestCase):
    def test_sides_and_disks_form_one_title_in_order(self) -> None:
        titles = group(["Quest disk 2 side B.dsk", "Quest disk 1 side A.dsk",
                        "Quest disk 1 side B.dsk", "Quest disk 2 side A.dsk"])
        self.assertEqual(len(titles), 1)
        self.assertEqual([(d, s) for d, s, _ in positions(titles[0])], [(1, "A"), (1, "B"), (2, "A"), (2, "B")])
        self.assertEqual(titles[0].review, [])

    def test_same_name_in_different_folders_stays_separate(self) -> None:
        self.assertEqual(len(group(["a/Quest side A.dsk", "b/Quest side B.dsk"])), 2)

    def test_overlapping_releases_are_split_and_flagged(self) -> None:
        titles = group(["Blaster disk 1.dsk", "Blaster disk 2.dsk", "Blaster side A.dsk", "Blaster side B.dsk"])
        self.assertEqual(len(titles), 2)
        self.assertTrue(all(t.review for t in titles))
        self.assertEqual(sorted(len(t.images) for t in titles), [2, 2])

    def test_data_disks_follow_program_disks(self) -> None:
        titles = group(["Magic.dsk", "Magic data disk - Math.dsk", "Magic data disk - Science.dsk"])
        self.assertEqual(len(titles), 1)
        self.assertEqual([(d, s) for d, s, _ in positions(titles[0])], [(1, "A"), (2, "A"), (3, "A")])

    def test_data_disk_sides_stay_paired(self) -> None:
        titles = group(["Animals.dsk", "Animals data disk side 1.dsk", "Animals data disk side 2.dsk"])
        self.assertEqual([(d, s) for d, s, _ in positions(titles[0])], [(1, "A"), (2, "A"), (2, "B")])

    def test_orphan_data_disks_grouped_and_flagged(self) -> None:
        titles = group(["Words data disk - A.dsk", "Words data disk - B.dsk"])
        self.assertEqual(len(titles), 1)
        self.assertTrue(titles[0].review)

    def test_missing_first_disk_flagged(self) -> None:
        titles = group(["Voyage disk 2.dsk", "Voyage disk 3.dsk"])
        self.assertIn("no disk 1 side A", titles[0].review[0])


class BuildTests(unittest.TestCase):
    def test_build_end_to_end_with_overrides_and_compat(self) -> None:
        files = ["math/Number Fun side A.dsk", "math/Number Fun side B.dsk", "Mystery Thing.dsk"]
        with tempfile.TemporaryDirectory() as library, tempfile.TemporaryDirectory() as rules:
            manifest = {"files": [{"path": p, "size": 143360, "sha256": f"{n:064x}"} for n, p in enumerate(files)]}
            write_json(os.path.join(library, "manifest.json"), manifest)
            write_json(os.path.join(library, "compat.json"), {"results": {f"{0:064x}": {"requirement": "IIplus64K", "detail": "booted"}}})
            write_json(os.path.join(rules, "subject_rules.json"), [{"subject": "Math", "pattern": "number"}])
            write_json(os.path.join(rules, "subject_overrides.json"), {"mystery-thing": {"subject": "Literature"}})
            built = catalog.build(library, rules)
        by_id = {t["id"]: t for t in built["titles"]}
        number_fun = by_id["math-number-fun"]
        self.assertEqual(number_fun["subject"], "Math")
        self.assertEqual(number_fun["requirement"], "IIplus64K")
        self.assertEqual(number_fun["requirementSource"], "sweep")
        self.assertEqual(number_fun["boot"], {"drive1": files[0], "drive2": files[1]})
        self.assertEqual(by_id["mystery-thing"]["subject"], "Literature")
        self.assertFalse(number_fun["hidden"])

    def test_undecided_sweep_keeps_file_name_hint(self) -> None:
        files = ["Lesson (no boot).dsk"]
        with tempfile.TemporaryDirectory() as library, tempfile.TemporaryDirectory() as rules:
            write_json(os.path.join(library, "manifest.json"), {"files": [{"path": files[0], "size": 143360, "sha256": "0" * 64}]})
            write_json(os.path.join(library, "compat.json"), {"results": {"0" * 64: {"requirement": "unknown", "detail": "did not boot"}}})
            write_json(os.path.join(rules, "subject_rules.json"), [{"subject": "Reading", "pattern": "lesson"}])
            (record,) = catalog.build(library, rules)["titles"]
        self.assertEqual((record["requirement"], record["requirementSource"]), ("noboot", "filename"))

    def test_title_without_subject_is_hidden(self) -> None:
        files = ["Unmatched Thing.dsk"]
        with tempfile.TemporaryDirectory() as library, tempfile.TemporaryDirectory() as rules:
            manifest = {"files": [{"path": p, "size": 143360, "sha256": f"{n:064x}"} for n, p in enumerate(files)]}
            write_json(os.path.join(library, "manifest.json"), manifest)
            write_json(os.path.join(rules, "subject_rules.json"), [{"subject": "Math", "pattern": "number"}])
            built = catalog.build(library, rules)
        (record,) = built["titles"]
        self.assertIsNone(record["subject"])
        self.assertTrue(record["hidden"])

    def test_bundled_rules_only_use_the_ten_subjects(self) -> None:
        with open(os.path.join(RULES_DIR, "subject_rules.json")) as handle:
            rules = json.load(handle)
        catalog.SubjectRules(rules)
        self.assertEqual(set(r["subject"] for r in rules) - {None}, set(catalog.SUBJECTS))

    def test_unknown_override_subject_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as library, tempfile.TemporaryDirectory() as rules:
            write_json(os.path.join(library, "manifest.json"), {"files": [{"path": "X.dsk", "size": 143360, "sha256": "0" * 64}]})
            write_json(os.path.join(rules, "subject_overrides.json"), {"x": {"subject": "Cooking"}})
            with self.assertRaises(ValueError):
                catalog.build(library, rules)


if __name__ == "__main__":
    unittest.main()
