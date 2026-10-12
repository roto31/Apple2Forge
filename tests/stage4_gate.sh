#!/bin/bash
set -euo pipefail

# Stage 4 gate: automated coverage.
#   G1  every session delivered all its keys, ended cleanly, and replayed
#       byte-identical (collect data and probe log) on a second run
#   G2  every session met its expectations (game modes: disk loaded after the
#       mode was chosen) and the six game modes each ran code no other did
#   G3  the report has a percentage per loaded region and an unreached list
# Exit codes: 0 success, 1 gate failed, 2 config error.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DEFAULT_DISK="${REPO_ROOT}/MECC-A170 Number Munchers v1.3 (4am crack)/MECC-A170 Number Munchers v1.3 (4am crack).dsk"
readonly DEFAULT_BINARY="${REPO_ROOT}/build/a2emu-norom/a2emu"
readonly COVERAGE_DIR="${REPO_ROOT}/work/_gate/stage4/coverage"
readonly GAME_MODE_SESSIONS="multiples factors primes equality inequality computer-decides"
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/stage4_gate.log"
SUMMARY_TITLE="Stage 4 gate"
# shellcheck source=../tools/lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<'EOF'
Usage: tests/stage4_gate.sh [--disk PATH] [--binary PATH]

Runs tools/40_coverage.sh into work/_gate/stage4/coverage and checks replay
determinism (G1), session targets (G2) and the coverage report (G3).
  --disk PATH     default: the Number Munchers .dsk in the repo root folder
  --binary PATH   default: build/a2emu-norom/a2emu
EOF
}

disk="${DEFAULT_DISK}"
binary="${DEFAULT_BINARY}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --disk) disk="${2:?--disk needs a path}"; shift 2 ;;
    --binary) binary="${2:?--binary needs a path}"; shift 2 ;;
    *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "${LOG_DIR}"
echo "=== stage4_gate.sh $(date '+%Y-%m-%d %H:%M:%S %z')" >> "${LOG_FILE}"

# check_report PYTHON_CHECK → prints the result line; non-zero exit on failure.
check_report() {
  python3 -I - "${COVERAGE_DIR}/coverage.json" "${GAME_MODE_SESSIONS}" <<<"$1"
}

# ── G1: replays are exact ───────────────────────────────────────────
gate_start="$(date +%s)"
echo "[G1] Run all sessions; each must be complete and deterministic"
if ! "${REPO_ROOT}/tools/40_coverage.sh" --disk "${disk}" --binary "${binary}" --out "${COVERAGE_DIR}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "G1: Exact replays" "${gate_start}" "tools/40_coverage.sh failed; run it with --out ${COVERAGE_DIR} to see which session."
fi
if ! result="$(check_report '
import json, sys
report = json.load(open(sys.argv[1]))
bad = [s["session"] for s in report["sessions"]
       if not (s["deterministic"] and s["ended_cleanly"] and s["keys"].split("/")[0] == s["keys"].split("/")[1])]
count = len(report["sessions"])
print(f"not exact or incomplete: {bad}" if bad else f"{count} sessions, all keys delivered, ended cleanly, identical on replay")
sys.exit(1 if bad else 0)
' 2>&1)"; then
  fail_gate "G1: Exact replays" "${gate_start}" "${result}"
fi
echo "    ${result}"
pass_gate "G1: Exact replays" "${gate_start}"

# ── G2: session targets ─────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[G2] Session targets"
if ! result="$(check_report '
import json, sys
report = json.load(open(sys.argv[1]))
sessions = {s["session"]: s for s in report["sessions"]}
problems = [f"{n}: expectation not met" for n, s in sessions.items() if not s["expectations_met"]]
for mode in sys.argv[2].split():
    if mode not in sessions:
        problems.append(f"{mode}: session missing")
    elif sessions[mode]["bytes_only_this_session"] == 0 and mode != "multiples":
        problems.append(f"{mode}: ran no code that other sessions did not")
print("; ".join(problems) if problems else "all expectations met; every game mode loaded from disk after it was chosen")
sys.exit(1 if problems else 0)
' 2>&1)"; then
  fail_gate "G2: Session targets" "${gate_start}" "${result}"
fi
echo "    ${result}"
pass_gate "G2: Session targets" "${gate_start}"

# ── G3: report ──────────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[G3] Coverage report"
if ! result="$(check_report '
import json, sys
report = json.load(open(sys.argv[1]))
if not report["regions"] or report["loaded_bytes"] == 0 or "unreached_ranges" not in report:
    print("report has no regions or no unreached list"); sys.exit(1)
percent, loaded, ranges = report["percent_of_loaded_range"], report["loaded_bytes"], len(report["unreached_ranges"])
print(f"{percent}% of {loaded} loaded bytes executed; {ranges} unreached ranges listed")
' 2>&1)"; then
  fail_gate "G3: Report" "${gate_start}" "${result}"
fi
echo "    ${result}"
ARTIFACTS+=("work/_gate/stage4/coverage/coverage.md")
pass_gate "G3: Report" "${gate_start}"

print_artifacts
print_summary "PASSED"
