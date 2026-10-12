#!/bin/bash
set -euo pipefail

# Stage 1 wrapper: gated run of tools/10_analyze.py on one disk image.
# Exit codes: 0 success, 1 runtime failure, 2 config error, 3 missing dependency.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly ANALYZER="${REPO_ROOT}/tools/10_analyze.py"
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/10_analyze.log"
SUMMARY_TITLE="Stage 1 analyze"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<'EOF'
Usage: tools/10_analyze.sh IMAGE [--out DIR] [--dry-run] [--help]

Analyzes an Apple II disk image (read-only) and writes analysis.json and
analysis.md to DIR (default: work/<disk-slug>/). Unsupported formats such as
.nib are reported in the output, not treated as failures.

  --out DIR   Output folder.
  --dry-run   Show what would run; change nothing.
  --help      Show this help.
EOF
}

IMAGE_PATH=""
OUT_DIR=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --out)
      if [[ $# -lt 2 ]]; then echo "ERROR: --out needs a folder" >&2; exit 2; fi
      OUT_DIR="$2"; shift 2 ;;
    -*) echo "ERROR: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "${IMAGE_PATH}" ]]; then echo "ERROR: only one image per run" >&2; exit 2; fi
      IMAGE_PATH="$1"; shift ;;
  esac
done
if [[ -z "${IMAGE_PATH}" ]]; then
  echo "ERROR: no disk image given" >&2
  usage >&2
  exit 2
fi

if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="${REPO_ROOT}/work/$(disk_slug "${IMAGE_PATH}")"
fi

mkdir -p "${LOG_DIR}"
echo "=== 10_analyze.sh $(date '+%Y-%m-%d %H:%M:%S %z') image=${IMAGE_PATH} out=${OUT_DIR}" >> "${LOG_FILE}"

# ── Gate 0: input ───────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Input image"
if [[ ! -f "${IMAGE_PATH}" || ! -r "${IMAGE_PATH}" ]]; then
  echo "input missing or unreadable: ${IMAGE_PATH}" >> "${LOG_FILE}"
  fail_gate "Gate 0: Input readable" "${gate_start}" "Check the path: ls -l \"${IMAGE_PATH}\"" 2
fi
echo "    ${IMAGE_PATH} ($(stat -f %z "${IMAGE_PATH}") bytes)"
pass_gate "Gate 0: Input readable" "${gate_start}"

# ── Gate 1: dependencies ────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 1] Dependencies"
if ! command -v python3 >/dev/null; then
  fail_gate "Gate 1: python3 + analyzer present" "${gate_start}" "brew install python3" 3
fi
if [[ ! -f "${ANALYZER}" ]]; then
  fail_gate "Gate 1: python3 + analyzer present" "${gate_start}" "Missing ${ANALYZER}; restore it from Git: git checkout -- tools/10_analyze.py" 3
fi
pass_gate "Gate 1: python3 + analyzer present" "${gate_start}"

# ── Gate 2: run analyzer ────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 2] Analyze"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "    would run: python3 -I tools/10_analyze.py \"${IMAGE_PATH}\" --out \"${OUT_DIR}\""
  record_gate "Gate 2: Analyzer run" "DRY-RUN" 0
  record_gate "Gate 3: Outputs valid" "DRY-RUN" 0
  print_summary "DRY-RUN"
  exit 0
fi
if ! python3 -I "${ANALYZER}" "${IMAGE_PATH}" --out "${OUT_DIR}" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate 2: Analyzer run" "${gate_start}" \
    "The analyzer crashed (traceback above). Re-run by hand to see it:
  python3 -I tools/10_analyze.py \"${IMAGE_PATH}\" --out /tmp/analysis-debug"
fi
pass_gate "Gate 2: Analyzer run" "${gate_start}"

# ── Gate 3: outputs ─────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 3] Outputs"
if ! headline="$(python3 -I - "${OUT_DIR}/analysis.json" <<'EOF' 2>> "${LOG_FILE}"
import json, sys
analysis = json.load(open(sys.argv[1], encoding="utf-8"))
for key in ("schema_version", "input", "format", "summary"):
    if key not in analysis:
        raise SystemExit(f"analysis.json is missing '{key}'")
print(analysis["summary"]["headline"])
EOF
)"; then
  fail_gate "Gate 3: Outputs valid" "${gate_start}" "analysis.json is missing or malformed. Re-run this script; if it repeats, report the log."
fi
if [[ ! -s "${OUT_DIR}/analysis.md" ]]; then
  fail_gate "Gate 3: Outputs valid" "${gate_start}" "analysis.md was not written. Check folder permissions: ls -ld \"${OUT_DIR}\""
fi
ARTIFACTS+=("${OUT_DIR#"${REPO_ROOT}"/}/analysis.json" "${OUT_DIR#"${REPO_ROOT}"/}/analysis.md")
pass_gate "Gate 3: Outputs valid" "${gate_start}"

echo
echo "Result: ${headline}"
print_artifacts
print_summary "PASSED"
