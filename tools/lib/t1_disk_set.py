"""Order T1 wrap disk images and group dropped disks into titles.

Usage:
  python3 -I tools/lib/t1_disk_set.py DISK.dsk [DISK2.dsk ...]
  python3 -I tools/lib/t1_disk_set.py --group DISK.dsk [DISK2.dsk ...]

Without --group: one title — JSON with title, sides (path, label, bundleFile, startupDrive, sha256).
With --group: JSON array of {title, paths, sideCount} for Apple2Forge Build grouping.

Exit 2 on overlapping disk/side labels or unreadable paths.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from library_catalog import (  # noqa: E402
    SIDE_NAMES,
    DiskImage,
    group_images,
    menu_title,
    parse_image,
)


def file_sha256(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def parse_disk_file(path: str) -> DiskImage:
    abs_path = os.path.abspath(path)
    if not os.path.isfile(abs_path):
        raise FileNotFoundError(abs_path)
    directory = os.path.dirname(abs_path)
    folder_key = os.path.basename(directory) if directory else ""
    name = os.path.basename(abs_path)
    catalog_path = f"{folder_key}/{name}" if folder_key else name
    image = parse_image(catalog_path, file_sha256(abs_path))
    image.path = abs_path
    return image


def side_label(image: DiskImage) -> str:
    suffix = f" ({image.label})" if image.label else ""
    return f"Disk {image.disk} Side {SIDE_NAMES[image.side]}{suffix}"


def bundle_file_name(index: int) -> str:
    return "disk.dsk" if index == 0 else f"side-{index + 1:02d}.dsk"


def startup_drive(index: int) -> str:
    if index == 0:
        return "1"
    if index == 1:
        return "2"
    return "-"


def assert_no_position_collisions(images: list[DiskImage]) -> None:
    positions = [(m.disk, m.side) for m in images]
    if len(set(positions)) != len(positions):
        seen: dict[tuple[int, int], str] = {}
        for image in images:
            key = (image.disk, image.side)
            if key in seen:
                print(
                    f"ERROR: {image.path} and {seen[key]} both claim "
                    f"disk {key[0]} side {SIDE_NAMES[key[1]]}; rename one.",
                    file=sys.stderr,
                )
                sys.exit(2)
            seen[key] = image.path


def disk_set_record(images: list[DiskImage]) -> dict:
    ordered = sorted(images, key=lambda m: (m.disk, m.side, m.stem.lower()))
    assert_no_position_collisions(ordered)
    sides = []
    for index, image in enumerate(ordered):
        sides.append(
            {
                "path": image.path,
                "label": side_label(image),
                "bundleFile": bundle_file_name(index),
                "startupDrive": startup_drive(index),
                "sha256": image.sha256,
            }
        )
    return {"title": ordered[0].title, "bootPath": ordered[0].path, "sides": sides}


def group_record(title_images: list[DiskImage], title_name: str) -> dict:
    ordered = sorted(title_images, key=lambda m: (m.disk, m.side, m.stem.lower()))
    return {
        "title": title_name,
        "paths": [m.path for m in ordered],
        "sideCount": len(ordered),
    }


def group_paths(paths: list[str]) -> list[dict]:
    images = [parse_disk_file(p) for p in paths]
    titles = group_images(images)
    out: list[dict] = []
    for title in titles:
        name = menu_title(title)
        for image in title.images:
            if not os.path.isabs(image.path):
                raise RuntimeError(f"internal error: expected absolute path for {image.path}")
        out.append(group_record(title.images, name))
    return out


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--group", action="store_true", help="Split paths into titles (Build window)")
    parser.add_argument("disks", nargs="+", help="140K disk image paths")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.group:
            print(json.dumps(group_paths(args.disks), indent=2))
            return 0
        images = [parse_disk_file(p) for p in args.disks]
        print(json.dumps(disk_set_record(images), indent=2))
        return 0
    except FileNotFoundError as error:
        print(f"ERROR: cannot read {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
