#!/bin/bash
set -euo pipefail

# Boot check for a T1 app built by tools/20_wrap_t1.sh: runs the app's own
# bundled emulator and disk headless on the Apple II+ with your installed ROM,
# and reports whether the disk starts (same judgement as the library sweep).
# It does not play the program; a pass means the disk starts and shows a screen.
# Exit codes: 0 boots, 1 did not boot or gate failed, 2 config error, 3 missing dependency.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly CHECK_TOOL="${REPO_ROOT}/tools/lib/t1_boot_check.py"
readonly DEFAULT_ROM_DIR="${HOME}/Library/Application Support/Apple2Forge/roms"
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/25_check_t1.log"
SUMMARY_TITLE="T1 boot check"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<'EOF'
Usage: tools/25_check_t1.sh APP.app [--rom-dir=DIR] [--frames=N] [--dry-run] [--help]

Boots the T1 app's bundled emulator and disk without a window on the Apple II+
and reports whether the disk starts: the screen after N frames (default 1800,
30 s; blank screens are retried to 7200) must not be blank, an error, a bare
prompt or the Disk II boot ROM. It does not play the program.

  --rom-dir=DIR  Folder holding apple2plus.rom
                 (default: ~/Library/Application Support/Apple2Forge/roms)
  --frames=N     Frames to run before judging (60 per second)
  --dry-run      Check inputs only; boot nothing.
EOF
}

app=""
rom_dir="${DEFAULT_ROM_DIR}"
frames=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --rom-dir=*) rom_dir="${1#*=}"; shift ;;
    --frames=*) frames="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "${app}" ]]; then echo "ERROR: only one app" >&2; exit 2; fi
      app="${1%/}"; shift ;;
  esac
done
if [[ -z "${app}" ]]; then usage >&2; exit 2; fi
if [[ -n "${frames}" && ! "${frames}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --frames needs a whole number" >&2; exit 2
fi

mkdir -p "${LOG_DIR}"
echo "=== 25_check_t1.sh $(date '+%Y-%m-%d %H:%M:%S %z') app=${app}" >> "${LOG_FILE}"

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
if ! command -v python3 >/dev/null 2>&1; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "python3 is missing (xcode-select --install)." 3
fi
if [[ ! -x "${app}/Contents/MacOS/a2emu" || ! -f "${app}/Contents/Resources/disk.dsk" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "${app} is not a T1 app (no Contents/MacOS/a2emu or Contents/Resources/disk.dsk)." 2
fi
if [[ ! -r "${rom_dir}/apple2plus.rom" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "No apple2plus.rom in ${rom_dir}. Run tools/05_fetch_rom.sh --install." 2
fi
echo "    app: ${app}"
pass_gate "Gate 0: Inputs" "${gate_start}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[dry-run] would boot ${app##*/} headless on the Apple II+"
  print_summary "PASSED (dry run)"
  exit 0
fi

# ── Gate 1: headless boot ───────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 1] Headless boot on the Apple II+ (up to 2 minutes)"
check_args=(--app "${app}" --rom-dir "${rom_dir}")
if [[ -n "${frames}" ]]; then check_args+=(--frames "${frames}"); fi
status=0
result="$(python3 -I "${CHECK_TOOL}" "${check_args[@]}" 2>>"${LOG_FILE}")" || status=$?
echo "${result}" >> "${LOG_FILE}"
if [[ -z "${result}" ]]; then
  fail_gate "Gate 1: Headless boot" "${gate_start}" "The check could not run; see ${LOG_FILE#"${REPO_ROOT}"/}." 2
fi
detail="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["detail"])' "${result}")"
echo "    ${detail}"
if [[ "${status}" -eq 2 ]]; then
  fail_gate "Gate 1: Headless boot" "${gate_start}" "Could not check: ${detail}" 2
fi
if [[ "${status}" -ne 0 ]]; then
  fail_gate "Gate 1: Headless boot" "${gate_start}" "Did not boot: ${detail}"
fi
pass_gate "Gate 1: Headless boot" "${gate_start}"

print_summary "PASSED"
