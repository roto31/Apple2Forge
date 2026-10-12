"""Boot a T1 app's own emulator and disk headless on the Apple II+ and report whether it starts.

Usage: python3 -I tools/lib/t1_boot_check.py --app PATH.app --rom-dir DIR [--frames N]
Prints one JSON line: {"app", "booted", "detail"}. Exit 0 booted, 1 did not boot,
2 bad input or an app too old to check ("booted": null).

The judgement is the library compatibility sweep's (compat_sweep.judge): after --frames
frames the screen must show something other than a blank page, an error, a bare prompt
or the Disk II boot ROM. It shows the disk starts; it does not play the program.
"""
import argparse
import json
import os
import sys

# Run with python3 -I, which leaves this script's folder off the import path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compat_sweep  # noqa: E402

EMULATOR_IN_BUNDLE = os.path.join("Contents", "MacOS", "a2emu")
DISK_IN_BUNDLE = os.path.join("Contents", "Resources", "disk.dsk")
ROM_NAME = "apple2plus.rom"
# a2emu builds from before the snapshot-frame patch reject the option the check needs.
OLD_EMULATOR_MESSAGE = "Invalid option '--snapshot-frame"


def bundle_paths(app: str) -> tuple[str, str]:
    """Return (emulator, disk) inside a T1 app; ValueError if the layout is not a T1 app's."""
    emulator = os.path.join(app, EMULATOR_IN_BUNDLE)
    disk = os.path.join(app, DISK_IN_BUNDLE)
    if not os.path.isfile(emulator) or not os.access(emulator, os.X_OK):
        raise ValueError(f"{app} has no executable {EMULATOR_IN_BUNDLE}; is it a T1 app?")
    if not os.path.isfile(disk):
        raise ValueError(f"{app} has no {DISK_IN_BUNDLE}; is it a T1 app?")
    return emulator, disk


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--rom-dir", required=True)
    parser.add_argument("--frames", type=int, default=compat_sweep.DEFAULT_FRAMES)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        emulator, disk = bundle_paths(args.app)
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    if not os.path.isfile(os.path.join(args.rom_dir, ROM_NAME)):
        print(f"ERROR: no {ROM_NAME} in {args.rom_dir}", file=sys.stderr)
        return 2
    sweep_args = argparse.Namespace(emulator=emulator, rom_dir=args.rom_dir, frames=args.frames)
    boot = compat_sweep.run_boot(sweep_args, "iiplus", disk, None)
    if OLD_EMULATOR_MESSAGE in boot.detail:
        print(json.dumps({"app": args.app, "booted": None,
                          "detail": "the app's emulator predates headless snapshots; "
                                    "rebuild the app with tools/20_wrap_t1.sh, then check again"}))
        return 2
    print(json.dumps({"app": args.app, "booted": boot.booted, "detail": boot.detail}))
    return 0 if boot.booted else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
