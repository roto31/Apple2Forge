#!/bin/bash
set -euo pipefail

# Stage 6a: download the educational disk library (operator action).
# Fetches the .dsk images under images/educational/ on the asimov mirror whose
# file names do not contain "4am", into DEST/disks/, and writes DEST/manifest.json
# with each file's size and SHA-256. Re-running skips finished files (resume).
# Disk images are copyrighted: this is for owners of the original software and
# never writes into the repository or an app bundle.
# Exit codes: 0 success, 1 gate failed, 2 config error, 3 missing dependency, 4 cancelled.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly FETCHER="${REPO_ROOT}/tools/lib/edu_fetch.py"
readonly DASHBOARD="${REPO_ROOT}/tools/lib/progress_dashboard.py"
readonly DEFAULT_DEST="${HOME}/Library/Application Support/Apple2Forge/library"
readonly MIN_FREE_KILOBYTES=$(( 1024 * 1024 ))
readonly LOG_DIR="${HOME}/Library/Logs/Apple2Forge"
LOG_FILE="${LOG_DIR}/library-download.log"
SUMMARY_TITLE="Stage 6a educational library download"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<EOF
Usage: tools/07_fetch_edu_library.sh [--dest=DIR] [--limit=N] [--progress=json]
                                     [--no-dashboard] [--dry-run] [--help]

Downloads the non-4am .dsk educational disk images (about 2,300 files,
about 330 MB) into DIR/disks/ and writes DIR/manifest.json.

  --dest=DIR       Library folder (default: ${DEFAULT_DEST}).
                   Refused if inside an .app bundle or not writable.
  --limit=N        Only the first N files (for tests).
  --progress=json  Machine-readable progress on stdout (one JSON object per
                   line, used by Apple2Forge.app); all other output to stderr.
  --no-dashboard   Do not open the browser progress page (port 8765).
  --dry-run        List what would be downloaded; write nothing.
  --help           This text.
EOF
}

DEST="${DEFAULT_DEST}"
LIMIT=0
JSON_PROGRESS=0
DASHBOARD_ON=1
DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --help|-h) usage; exit 0 ;;
    --dest=*) DEST="${arg#--dest=}" ;;
    --limit=*) LIMIT="${arg#--limit=}" ;;
    --progress=json) JSON_PROGRESS=1; DASHBOARD_ON=0 ;;
    --no-dashboard) DASHBOARD_ON=0 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "ERROR: unknown option ${arg}" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ ! "${LIMIT}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --limit must be a whole number" >&2
  exit 2
fi

# JSON mode: fd 3 carries progress to the caller; human output goes to stderr.
if [[ "${JSON_PROGRESS}" -eq 1 ]]; then
  exec 3>&1 1>&2
fi

mkdir -p "${LOG_DIR}"
echo "=== 07_fetch_edu_library.sh $(date '+%Y-%m-%d %H:%M:%S %z') dest=${DEST}" >> "${LOG_FILE}"

# ── Gate 0: prerequisites and destination ───────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Prerequisites and destination"
for tool in python3 df; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    fail_gate "Gate 0: Prerequisites" "${gate_start}" "Missing ${tool}. Install the Xcode command-line tools: xcode-select --install" 3
  fi
done
if [[ "${DEST}" != /* ]]; then
  fail_gate "Gate 0: Prerequisites" "${gate_start}" "--dest must be an absolute path." 2
fi
case "${DEST}/" in
  *.app/*) fail_gate "Gate 0: Prerequisites" "${gate_start}" "${DEST} is inside an app bundle; writing there breaks the app's signature. Choose another folder." 2 ;;
esac
if [[ "${DRY_RUN}" -eq 0 ]]; then
  if ! mkdir -p "${DEST}" 2>>"${LOG_FILE}" || [[ ! -w "${DEST}" ]]; then
    fail_gate "Gate 0: Prerequisites" "${gate_start}" "Cannot write to ${DEST}. Choose a folder you own." 2
  fi
  free_kilobytes="$(df -Pk "${DEST}" | awk 'NR==2 {print $4}')"
  if [[ "${free_kilobytes}" -lt "${MIN_FREE_KILOBYTES}" ]]; then
    fail_gate "Gate 0: Prerequisites" "${gate_start}" "Only $(( free_kilobytes / 1024 )) MB free at ${DEST}; 1 GB is needed." 2
  fi
fi
pass_gate "Gate 0: Prerequisites" "${gate_start}"

# ── Gate 1: mirror listing ──────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 1] Read mirror listing"
fetch_args=(--dest "${DEST}" --limit "${LIMIT}")
if [[ "${JSON_PROGRESS}" -eq 1 ]]; then fetch_args+=(--progress-fd 3); fi
if [[ "${DRY_RUN}" -eq 1 ]]; then
  if ! python3 -I "${FETCHER}" "${fetch_args[@]}" --list-only 2>&1 | tee -a "${LOG_FILE}"; then
    fail_gate "Gate 1: Mirror listing" "${gate_start}" "Could not read the mirror. Check the network and https://mirrors.apple2.org.za/."
  fi
  pass_gate "Gate 1: Mirror listing" "${gate_start}"
  print_summary "PASSED (dry run)"
  exit 0
fi
pass_gate "Gate 1: Mirror listing (read during download)" "${gate_start}"

# ── Gate 2: download ────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 2] Download (resumes; Ctrl-C keeps finished files)"
status_file="${DEST}/.download-status.json"
dashboard_pid=""
if [[ "${DASHBOARD_ON}" -eq 1 ]]; then
  python3 -I "${DASHBOARD}" "${status_file}" "Educational library download" --open 2>>"${LOG_FILE}" &
  dashboard_pid=$!
fi
fetch_status=0
python3 -I "${FETCHER}" "${fetch_args[@]}" --status-file "${status_file}" 2> >(tee -a "${LOG_FILE}" >&2) || fetch_status=$?
if [[ -n "${dashboard_pid}" ]]; then
  echo "    dashboard stays up 5 minutes: http://127.0.0.1:8765/"
fi
case "${fetch_status}" in
  0) ;;
  4) fail_gate "Gate 2: Download" "${gate_start}" "Cancelled. Run the same command again to resume." 4 ;;
  *) fail_gate "Gate 2: Download" "${gate_start}" "Some files failed (listed as WARN above). Run the same command again to retry only those." ;;
esac
ARTIFACTS+=("${DEST}/disks/" "${DEST}/manifest.json")
pass_gate "Gate 2: Download" "${gate_start}"

# ── Gate 3: manifest check ──────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 3] Verify manifest against files on disk"
if ! python3 -I - "${DEST}" <<'PY' 2>&1 | tee -a "${LOG_FILE}"
import hashlib, json, os, sys
dest = sys.argv[1]
manifest = json.load(open(os.path.join(dest, "manifest.json")))
bad = [e["path"] for e in manifest["files"]
       if os.path.getsize(os.path.join(dest, "disks", e["path"])) != e["size"]]
print(f"    {manifest['file_count']} files, {manifest['total_bytes']} bytes, {len(bad)} size mismatches")
sys.exit(1 if bad or manifest["file_count"] == 0 else 0)
PY
then
  fail_gate "Gate 3: Manifest check" "${gate_start}" "Manifest and files disagree. Delete ${DEST}/manifest.json and re-run."
fi
pass_gate "Gate 3: Manifest check" "${gate_start}"

print_artifacts
print_summary "PASSED"
