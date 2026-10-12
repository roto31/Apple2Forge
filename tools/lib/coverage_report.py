"""Merge Stage 4 coverage sessions into one report.

Usage: python3 -I tools/lib/coverage_report.py COVERAGE_DIR

COVERAGE_DIR/sessions/<name>/ holds collect.json and session.json written by
tools/lib/coverage_session.py. Writes COVERAGE_DIR/coverage.json and
coverage.md: executed bytes against the address ranges the disk loads, branch
directions never taken, and unreached code entry points grouped into ranges.
Coverage is counted from decoded instructions, not from collect's code-range
markers. Addresses, counts and hashes only: no game or ROM bytes. Exit 1 on
missing input.
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from typing import Any

PAGE_SIZE = 0x100
FRONTIER_GAP = 0x20
FRONTIER_ROWS_IN_MARKDOWN = 40
MONITOR_ROM_START = 0xF800
CONDITIONAL_BRANCHES = {"BPL", "BMI", "BVC", "BVS", "BCC", "BCS", "BNE", "BEQ"}
OPERAND_SIZES = {"imp": 0, "acc": 0, "imm": 1, "zp": 1, "zpx": 1, "zpy": 1, "izx": 1,
                 "izy": 1, "rel": 1, "abs": 2, "abx": 2, "aby": 2, "ind": 2}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def load_opcode_table() -> dict[int, tuple[str, str]]:
    analyzer_path = Path(__file__).resolve().parent.parent / "10_analyze.py"
    spec = importlib.util.spec_from_file_location("analyzer", analyzer_path)
    if spec is None or spec.loader is None:
        fail(f"cannot load {analyzer_path}")
    analyzer = importlib.util.module_from_spec(spec)
    sys.modules["analyzer"] = analyzer
    spec.loader.exec_module(analyzer)
    return analyzer.build_opcode_table()


def decode_session(collect_path: Path, opcode_table: dict[int, tuple[str, str]]) -> tuple[set[tuple[int, int]], dict[int, set[int]]]:
    """Returns executed (address, byte) pairs and, per control-transfer site, its possible successors."""
    executed: set[tuple[int, int]] = set()
    successors: dict[int, set[int]] = {}
    for generation in json.loads(collect_path.read_text())["generations"]:
        for run in generation["code"]:
            start = int(run["addr"])
            code = json.loads(run["bytes"]) if isinstance(run["bytes"], str) else run["bytes"]
            offset = 0
            while offset < len(code) and code[offset] in opcode_table:
                mnemonic, mode = opcode_table[code[offset]]
                size = OPERAND_SIZES[mode]
                if offset + size >= len(code):
                    break
                address = start + offset
                executed.update((address + i, code[offset + i]) for i in range(1 + size))
                if mnemonic in CONDITIONAL_BRANCHES:
                    displacement = code[offset + 1] - 0x100 if code[offset + 1] >= 0x80 else code[offset + 1]
                    successors[address] = {address + 2, (address + 2 + displacement) & 0xFFFF}
                elif mnemonic in ("JSR", "JMP") and mode == "abs":
                    successors[address] = {code[offset + 1] | code[offset + 2] << 8}
                offset += 1 + size
    return executed, successors


def loaded_addresses(session_summary: dict[str, Any]) -> set[int]:
    pages = {sector["buffer"] >> 8 for sector in session_summary["sectors"]}
    return {page * PAGE_SIZE + i for page in pages for i in range(PAGE_SIZE)}


def contiguous_ranges(addresses: list[int], gap: int = 1) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    for address in sorted(addresses):
        if ranges and address - ranges[-1][1] <= gap:
            ranges[-1] = (ranges[-1][0], address)
        else:
            ranges.append((address, address))
    return ranges


def build_report(coverage_dir: Path) -> dict[str, Any]:
    session_dirs = sorted(p for p in (coverage_dir / "sessions").iterdir() if (p / "session.json").exists())
    if not session_dirs:
        fail(f"no sessions under {coverage_dir / 'sessions'}")
    opcode_table = load_opcode_table()
    executed_by_session: dict[str, set[tuple[int, int]]] = {}
    successors: dict[int, set[int]] = {}
    loaded: set[int] = set()
    summaries: dict[str, dict[str, Any]] = {}
    for session_dir in session_dirs:
        summary = json.loads((session_dir / "session.json").read_text())
        executed, session_successors = decode_session(session_dir / "collect.json", opcode_table)
        executed_by_session[session_dir.name] = executed
        for site, targets in session_successors.items():
            successors.setdefault(site, set()).update(targets)
        loaded |= loaded_addresses(summary)
        summaries[session_dir.name] = summary

    all_executed = set().union(*executed_by_session.values())
    executed_addresses = {address for address, _ in all_executed}
    regions = []
    for low, high in contiguous_ranges(sorted({a >> 8 for a in loaded})):
        span = range(low * PAGE_SIZE, (high + 1) * PAGE_SIZE)
        hit = sum(1 for a in span if a in executed_addresses)
        regions.append({"range": f"${low:02X}00-${high:02X}FF", "loaded_bytes": len(span),
                        "executed_bytes": hit, "percent": round(100 * hit / len(span), 1)})
    executed_in_loaded = len(executed_addresses & loaded)

    unreached: dict[int, list[int]] = {}
    one_way_branches = 0
    for site, targets in successors.items():
        missing = [t for t in targets if t not in executed_addresses and t < MONITOR_ROM_START]
        if len(targets) == 2 and len(missing) == 1:
            one_way_branches += 1
        for target in missing:
            unreached.setdefault(target, []).append(site)
    frontier = []
    for low, high in contiguous_ranges(list(unreached), FRONTIER_GAP):
        targets = [t for t in unreached if low <= t <= high]
        sites = sorted({s for t in targets for s in unreached[t]})
        frontier.append({"range": f"${low:04X}-${high:04X}", "entry_points": len(targets),
                         "reached_from": [f"${s:04X}" for s in sites[:6]], "sites": len(sites)})
    frontier.sort(key=lambda row: (-row["sites"], row["range"]))

    sessions = []
    for name, executed in executed_by_session.items():
        others = set().union(*(e for n, e in executed_by_session.items() if n != name))
        summary = summaries[name]
        sessions.append({
            "session": name, "keys": f"{summary['keys_delivered']}/{summary['keys_total']}",
            "ended_cleanly": summary["ended_cleanly"], "deterministic": summary["deterministic"],
            "sectors_read": len(summary["sectors"]), "executed_bytes": len(executed),
            "bytes_only_this_session": len(executed - others),
            "expectations_met": all(e["met"] for e in summary["expectations"]),
            "levels": summary.get("levels"),
        })
    return {
        "loaded_bytes": len(loaded),
        "executed_bytes_in_loaded_range": executed_in_loaded,
        "percent_of_loaded_range": round(100 * executed_in_loaded / len(loaded), 1) if loaded else 0.0,
        "executed_bytes_outside_loaded_range": len(executed_addresses - loaded),
        "regions": regions,
        "control_transfer_sites": len(successors),
        "one_way_conditional_branches": one_way_branches,
        "unreached_entry_points": len(unreached),
        "unreached_ranges": frontier,
        "sessions": sessions,
    }


def write_markdown(report: dict[str, Any], path: Path) -> None:
    lines = [
        "# Stage 4 coverage report", "",
        "Personal-use analysis of a user-supplied disk. Addresses and counts only.", "",
        f"- **{report['percent_of_loaded_range']}%** of the {report['loaded_bytes']} bytes the disk loads were executed "
        f"({report['executed_bytes_in_loaded_range']} bytes). The loaded range includes data, so 100% is not reachable.",
        f"- {report['executed_bytes_outside_loaded_range']} executed bytes lie outside it (ROM, zero page, copied code).",
        f"- {report['one_way_conditional_branches']} conditional branches only ever went one way; "
        f"{report['unreached_entry_points']} branch or call targets were never executed.", "",
        "## Loaded regions", "", "| Range | Loaded | Executed | % |", "|---|---|---|---|"]
    lines += [f"| {r['range']} | {r['loaded_bytes']} | {r['executed_bytes']} | {r['percent']} |" for r in report["regions"]]
    lines += ["", "## Sessions", "",
              "| Session | Keys | Ended | Deterministic | Sectors | Executed bytes | Only this session | Levels cleared |",
              "|---|---|---|---|---|---|---|---|"]
    lines += [f"| {s['session']} | {s['keys']} | {s['ended_cleanly']} | {s['deterministic']} | {s['sectors_read']} | "
              f"{s['executed_bytes']} | {s['bytes_only_this_session']} | "
              f"{s['levels']['levels_cleared'] if s.get('levels') else '—'} |" for s in report["sessions"]]
    lines += ["", f"## Unreached code (top {FRONTIER_ROWS_IN_MARKDOWN} ranges by number of sites leading there)", "",
              "| Range | Entry points | Sites | Reached from |", "|---|---|---|---|"]
    lines += [f"| {r['range']} | {r['entry_points']} | {r['sites']} | {', '.join(r['reached_from'])} |"
              for r in report["unreached_ranges"][:FRONTIER_ROWS_IN_MARKDOWN]]
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 1
    coverage_dir = Path(sys.argv[1])
    report = build_report(coverage_dir)
    (coverage_dir / "coverage.json").write_text(json.dumps(report, indent=2) + "\n")
    write_markdown(report, coverage_dir / "coverage.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
