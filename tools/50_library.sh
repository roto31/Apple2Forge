#!/bin/bash
set -euo pipefail

# Stage 6a: build the educational library catalog.
# Groups the downloaded disk images into titles (disks with side A/B), assigns
# one of the 10 subjects, merges compatibility-sweep results, and writes
# LIBRARY/library.json plus LIBRARY/review/{grouping,subject}-review.md.
# Exit codes: 0 success, 1 gate failed, 2 config error, 3 missing dependency.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly CATALOG_TOOL="${REPO_ROOT}/tools/lib/library_catalog.py"
readonly DEFAULT_LIBRARY="${HOME}/Library/Application Support/Apple2Forge/library"
readonly DEFAULT_RULES="${REPO_ROOT}/library"
readonly LOG_DIR="${HOME}/Library/Logs/Apple2Forge"
LOG_FILE="${LOG_DIR}/library-catalog.log"
SUMMARY_TITLE="Stage 6a library catalog"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<EOF
Usage: tools/50_library.sh [--library=DIR] [--rules=DIR] [--dry-run] [--help]

  --library=DIR  Folder with manifest.json and disks/ (default: ${DEFAULT_LIBRARY}).
  --rules=DIR    Folder with subject_rules.json, subject_overrides.json and
                 grouping_overrides.json (default: library/ in this repo).
  --dry-run      Check inputs only.
  --help         This text.
EOF
}

LIBRARY="${DEFAULT_LIBRARY}"
RULES="${DEFAULT_RULES}"
DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --help|-h) usage; exit 0 ;;
    --library=*) LIBRARY="${arg#--library=}" ;;
    --rules=*) RULES="${arg#--rules=}" ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "ERROR: unknown option ${arg}" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "${LOG_DIR}"
echo "=== 50_library.sh $(date '+%Y-%m-%d %H:%M:%S %z') library=${LIBRARY}" >> "${LOG_FILE}"

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
if ! command -v python3 >/dev/null 2>&1; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "python3 is missing. Install the Xcode command-line tools: xcode-select --install" 3
fi
if [[ ! -f "${LIBRARY}/manifest.json" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "No ${LIBRARY}/manifest.json. Download the library first (tools/07_fetch_edu_library.sh)." 2
fi
if [[ ! -f "${RULES}/subject_rules.json" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "No ${RULES}/subject_rules.json." 2
fi
pass_gate "Gate 0: Inputs" "${gate_start}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  print_summary "PASSED (dry run)"
  exit 0
fi

# ── Gate 1: build catalog ───────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 1] Build library.json"
if ! python3 -I "${CATALOG_TOOL}" "${LIBRARY}" "${RULES}" 2>&1 | tee -a "${LOG_FILE}"; then
  fail_gate "Gate 1: Build catalog" "${gate_start}" "Catalog build failed; the error is above. Check the rule files are valid JSON with known subjects."
fi
ARTIFACTS+=("${LIBRARY}/library.json" "${LIBRARY}/review/grouping-review.md" "${LIBRARY}/review/subject-review.md")
pass_gate "Gate 1: Build catalog" "${gate_start}"

# ── Gate 2: every image placed exactly once, every boot disk exists ─
gate_start="$(date +%s)"
echo "[Gate 2] Check catalog against manifest"
if ! python3 -I - "${LIBRARY}" <<'PY' 2>&1 | tee -a "${LOG_FILE}"
import json, os, sys
library = sys.argv[1]
manifest = json.load(open(os.path.join(library, "manifest.json")))
catalog = json.load(open(os.path.join(library, "library.json")))
placed = [s["path"] for t in catalog["titles"] for d in t["disks"] for s in d["sides"]]
expected = {f["path"] for f in manifest["files"]}
duplicates = len(placed) - len(set(placed))
missing = expected - set(placed)
unknown = set(placed) - expected
boot_missing = [t["id"] for t in catalog["titles"]
                if not os.path.isfile(os.path.join(library, "disks", t["boot"]["drive1"]))]
bad_subject = [t["id"] for t in catalog["titles"] if t["subject"] not in catalog["subjects"] + [None]]
print(f"    placed {len(set(placed))}/{len(expected)}; duplicates {duplicates}; missing {len(missing)}; "
      f"unknown {len(unknown)}; boot disk missing {len(boot_missing)}; bad subject {len(bad_subject)}")
sys.exit(1 if duplicates or missing or unknown or boot_missing or bad_subject else 0)
PY
then
  fail_gate "Gate 2: Catalog check" "${gate_start}" "library.json does not match the downloaded files. Re-run the download, then this script."
fi
pass_gate "Gate 2: Catalog check" "${gate_start}"

print_artifacts
print_summary "PASSED"
