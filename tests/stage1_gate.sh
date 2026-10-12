#!/bin/bash
set -euo pipefail

# Stage 1 verification gate: unit tests, then the Number Munchers assertions
# from PROMPT.md, then the optional .nib "unsupported" check.
# Exit codes: 0 success, 1 gate failed, 2 config error.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DEFAULT_DISK="${REPO_ROOT}/MECC-A170 Number Munchers.dsk"
readonly NIB_SAMPLE="/Volumes/Storage/Installer Files/APPLE-II-DISK-IMAGES/educational/mecc/NumberMunchers.DSK"
readonly NIB_OUT="${REPO_ROOT}/work/_gate/nib-sample"
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/stage1_gate.log"
SUMMARY_TITLE="Stage 1 gate"
# shellcheck source=../tools/lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
Usage: tests/stage1_gate.sh [DISK_IMAGE]

Runs the Stage 1 gate: analyzer unit tests, then asserts the Number Munchers
disk reports "custom MECC loader, entry $3000, already cracked, 3 catalog
entries". If the .nib sample on /Volumes/Storage is mounted, also checks it is
reported unsupported (otherwise that row is SKIPPED, not PASSED).
EOF
  exit 0
fi
DISK="${1:-${DEFAULT_DISK}}"
DISK_OUT="${REPO_ROOT}/work/$(disk_slug "${DISK}")"
readonly DISK_OUT

mkdir -p "${LOG_DIR}"
echo "=== stage1_gate.sh $(date '+%Y-%m-%d %H:%M:%S %z') disk=${DISK}" >> "${LOG_FILE}"

# Reads one dotted path from analysis.json, e.g. summary.entry_point.
json_field() {
  python3 -I - "$1" "$2" <<'EOF'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for key in sys.argv[2].split("."):
    value = value[int(key)] if isinstance(value, list) else value[key]
print(json.dumps(value) if isinstance(value, (dict, list, bool)) or value is None else value)
EOF
}

# assert_field GATE_NAME JSON_FILE FIELD EXPECTED
assert_field() {
  local gate_name="$1" json_file="$2" field_path="$3" expected="$4" started actual
  started="$(date +%s)"
  actual="$(json_field "${json_file}" "${field_path}" 2>> "${LOG_FILE}" || echo "<missing>")"
  echo "assert ${field_path}: expected=${expected} actual=${actual}" >> "${LOG_FILE}"
  if [[ "${actual}" != "${expected}" ]]; then
    fail_gate "${gate_name}" "${started}" \
      "${field_path} is '${actual}', expected '${expected}'. Inspect: ${json_file%/*}/analysis.md"
  fi
  echo "    ${field_path} = ${actual}"
  pass_gate "${gate_name}" "${started}"
}

# ── Gate A: unit tests ──────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate A] Analyzer unit tests"
if ! python3 -I "${REPO_ROOT}/tests/test_10_analyze.py" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate A: Unit tests" "${gate_start}" "Run them directly to see the failure: python3 -I tests/test_10_analyze.py"
fi
pass_gate "Gate A: Unit tests" "${gate_start}"

# ── Gate B: analyze Number Munchers ─────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate B] Analyze ${DISK##*/}"
if [[ ! -f "${DISK}" ]]; then
  fail_gate "Gate B: Analyze test disk" "${gate_start}" \
    "Test disk not found. Put it at the repo root or pass its path: tests/stage1_gate.sh /path/to/disk.dsk" 2
fi
if ! "${REPO_ROOT}/tools/10_analyze.sh" "${DISK}" --out "${DISK_OUT}" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate B: Analyze test disk" "${gate_start}" "The wrapper failed; its own gate table is in the log above."
fi
ARTIFACTS+=("${DISK_OUT#"${REPO_ROOT}"/}/analysis.json" "${DISK_OUT#"${REPO_ROOT}"/}/analysis.md")
pass_gate "Gate B: Analyze test disk" "${gate_start}"

# ── Gate C: PROMPT.md assertions ────────────────────────────────────
echo "[Gate C] Assertions"
readonly ANALYSIS_JSON="${DISK_OUT}/analysis.json"
assert_field "Gate C1: Custom MECC loader" "${ANALYSIS_JSON}" "boot.loader.label" "custom MECC loader"
assert_field "Gate C2: Entry point \$3000" "${ANALYSIS_JSON}" "summary.entry_point" "\$3000"
assert_field "Gate C3: Already cracked" "${ANALYSIS_JSON}" "summary.protection_status" "already-cracked"
assert_field "Gate C3b: All 7 crack patches present" "${ANALYSIS_JSON}" "protection.known_crack_checks.0.matched" "7"
assert_field "Gate C4: 3 catalog entries" "${ANALYSIS_JSON}" "summary.catalog_entry_count" "3"
assert_field "Gate C5: DOS order, apple2tc-readable" "${ANALYSIS_JSON}" "format.apple2tc_readable" "true"

# ── Gate D: .nib sample reported unsupported ────────────────────────
echo "[Gate D] .nib sample"
if [[ -f "${NIB_SAMPLE}" ]]; then
  gate_start="$(date +%s)"
  if ! "${REPO_ROOT}/tools/10_analyze.sh" "${NIB_SAMPLE}" --out "${NIB_OUT}" >> "${LOG_FILE}" 2>&1; then
    fail_gate "Gate D: .nib reported unsupported" "${gate_start}" "The wrapper failed on the .nib sample; see the log."
  fi
  assert_field "Gate D: .nib reported unsupported" "${NIB_OUT}/analysis.json" "format.kind" "nib"
else
  skip_gate "Gate D: .nib reported unsupported" "sample not mounted at ${NIB_SAMPLE%/*}"
fi

echo
print_artifacts
print_summary "PASSED"
