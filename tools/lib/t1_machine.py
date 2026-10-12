"""Choose Apple ][+ vs enhanced //e for a T1 wrap (same rules as compat_sweep).

Usage: python3 -I tools/lib/t1_machine.py --emulator PATH --rom-dir DIR DISK [DISK2]
       python3 -I tools/lib/t1_machine.py --model iiplus|iie

Prints JSON: {machine, requirement, detail}. Exit 2 when auto mode cannot boot.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compat_sweep  # noqa: E402

MACHINE_FOR = {
    compat_sweep.REQUIREMENT_IIPLUS: "iiplus",
    compat_sweep.REQUIREMENT_IIE: "iie",
}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--emulator", required=True)
    parser.add_argument("--rom-dir", required=True)
    parser.add_argument("--frames", type=int, default=compat_sweep.DEFAULT_FRAMES)
    parser.add_argument("--model", choices=("auto", "iiplus", "iie"), default="auto")
    parser.add_argument("disks", nargs="+")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.model != "auto":
        out = {"machine": args.model, "requirement": None, "detail": f"--model={args.model}"}
        print(json.dumps(out, indent=2))
        return 0
    drive1 = args.disks[0]
    drive2 = args.disks[1] if len(args.disks) > 1 else None
    if not os.path.isfile(drive1):
        print(f"ERROR: cannot read {drive1}", file=sys.stderr)
        return 2
    names = " ".join(os.path.basename(p) for p in args.disks)
    sweep_args = argparse.Namespace(emulator=args.emulator, rom_dir=args.rom_dir, frames=args.frames)
    result = compat_sweep.classify_boot(sweep_args, names, drive1, drive2)
    machine = MACHINE_FOR.get(result["requirement"])
    if not machine:
        print(f"ERROR: {result['detail']}", file=sys.stderr)
        return 2
    if machine == "iie":
        for rom in ("apple2e-enhanced.rom", "apple2e-video.rom"):
            if not os.path.isfile(os.path.join(args.rom_dir, rom)):
                print(
                    f"ERROR: this disk needs the Apple //e; install {rom} "
                    f"(tools/05_fetch_rom.sh --install --model=iie)",
                    file=sys.stderr,
                )
                return 2
    print(json.dumps({"machine": machine, "requirement": result["requirement"], "detail": result["detail"]},
                     indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
