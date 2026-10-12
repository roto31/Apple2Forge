#!/usr/bin/env python3
"""Summarise one recorded play session: keys pressed and code executed.

Usage: python3 -I tools/lib/record_report.py RECORDING_DIR

RECORDING_DIR holds session.keys (a2emu --trace-keys lines "CYCLE CODE") and
collect.json (a2emu --collect). Writes RECORDING_DIR/record.json and record.md:
key count, executed bytes per memory region, and the share of each region's
pages that ran any code. Addresses and counts only: no game or ROM bytes.
Exit 1 on missing input.
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from typing import Any

REGIONS = [("$0000-$07FF", "zero page, stack, text screen", 0x0000, 0x07FF),
           ("$0800-$BFFF", "main RAM", 0x0800, 0xBFFF),
           ("$C000-$CFFF", "I/O and slot ROM", 0xC000, 0xCFFF),
           ("$D000-$F7FF", "Language Card RAM or BASIC ROM", 0xD000, 0xF7FF),
           ("$F800-$FFFF", "Monitor ROM or card RAM", 0xF800, 0xFFFF)]
PAGE_SIZE = 0x100


def load_coverage_report() -> Any:
    path = Path(__file__).resolve().parent / "coverage_report.py"
    spec = importlib.util.spec_from_file_location("coverage_report", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_report(recording: Path) -> dict[str, Any]:
    keys_file, collect_file = recording / "session.keys", recording / "collect.json"
    for needed in (keys_file, collect_file):
        if not needed.exists():
            print(f"ERROR: missing {needed}", file=sys.stderr)
            sys.exit(1)
    coverage = load_coverage_report()
    executed_pairs, _ = coverage.decode_session(collect_file, coverage.load_opcode_table())
    executed = {address for address, _ in executed_pairs}
    keys = [line for line in keys_file.read_text().splitlines() if line.strip()]
    regions = []
    for name, purpose, low, high in REGIONS:
        in_region = {a for a in executed if low <= a <= high}
        pages = {a // PAGE_SIZE for a in in_region}
        total_pages = (high - low + 1) // PAGE_SIZE
        regions.append({"range": name, "purpose": purpose, "executed_bytes": len(in_region),
                        "pages_with_code": len(pages), "pages": total_pages})
    return {"keys": len(keys), "executed_bytes": len(executed), "regions": regions}


def write_markdown(report: dict[str, Any], path: Path) -> None:
    lines = ["# Recorded session", "",
             f"- {report['keys']} keys pressed, {report['executed_bytes']} distinct bytes of code executed.",
             "- Replay it with the Replay button (or tools/45_record.sh --replay); the run is exact from boot.", "",
             "| Range | Holds | Executed bytes | Pages with code |", "|---|---|---|---|"]
    lines += [f"| {r['range']} | {r['purpose']} | {r['executed_bytes']} | {r['pages_with_code']}/{r['pages']} |"
              for r in report["regions"]]
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    recording = Path(sys.argv[1])
    report = build_report(recording)
    (recording / "record.json").write_text(json.dumps(report, indent=2) + "\n")
    write_markdown(report, recording / "record.md")
    print(f"{report['keys']} keys, {report['executed_bytes']} bytes of code executed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
