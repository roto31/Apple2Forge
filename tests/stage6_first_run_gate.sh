#!/bin/bash
set -euo pipefail

# Stage 6 first-run support: ROM fetch script options, Swift tests, bundled script.
# Exit codes: 0 PASS, 1 gate failed, 2 config error.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly FETCH_SCRIPT="${REPO_ROOT}/tools/05_fetch_rom.sh"
readonly PACKAGE_DIR="${REPO_ROOT}/app/Apple2Forge"
readonly APP="${REPO_ROOT}/build/Apple2Forge.app"
readonly BUNDLED_ROM_SCRIPT="${APP}/Contents/Resources/tools/05_fetch_rom.sh"
OUT_DIR="${REPO_ROOT}/work/_gate/stage6"
LOG_FILE="${OUT_DIR}/first_run_gate.log"
SUMMARY_TITLE="Stage 6 first-run gate"
# shellcheck source=../tools/lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

mkdir -p "${OUT_DIR}"
: > "${LOG_FILE}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/a2forge-first-run.XXXXXX")"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

# ── Gate F1: ROM script dry-run with work-dir ───────────────────────
gate_start="$(date +%s)"
echo "[Gate F1] 05_fetch_rom.sh --dry-run --work-dir"
if ! bash "${FETCH_SCRIPT}" --dry-run --work-dir="${WORK}/fetch" --model=iie >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate F1: ROM dry-run" "${gate_start}" "Dry-run failed; see ${LOG_FILE}."
fi
pass_gate "Gate F1: ROM dry-run" "${gate_start}"

# ── Gate F2: ROM script install to temp dirs (iiplus only, network) ─
gate_start="$(date +%s)"
echo "[Gate F2] 05_fetch_rom.sh --install with work-dir and install-dir"
install_dir="${WORK}/installed-roms"
if ! bash "${FETCH_SCRIPT}" --model=iiplus --install \
  --work-dir="${WORK}/iiplus" --install-dir="${install_dir}" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate F2: ROM install" "${gate_start}" "Install failed; see ${LOG_FILE}."
fi
if [[ ! -s "${install_dir}/apple2plus.rom" ]]; then
  fail_gate "Gate F2: ROM install" "${gate_start}" "apple2plus.rom missing in ${install_dir}."
fi
pass_gate "Gate F2: ROM install" "${gate_start}"

# ── Gate F3: Swift unit tests ───────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate F3] swift test (Apple2Forge)"
if ! (cd "${PACKAGE_DIR}" && swift test >> "${LOG_FILE}" 2>&1); then
  fail_gate "Gate F3: swift test" "${gate_start}" "swift test failed; see ${LOG_FILE}."
fi
pass_gate "Gate F3: swift test" "${gate_start}"

# ── Gate F4: bundled ROM script in app (if app exists) ────────────
gate_start="$(date +%s)"
echo "[Gate F4] Apple2Forge.app bundles tools/05_fetch_rom.sh"
if [[ ! -f "${BUNDLED_ROM_SCRIPT}" ]]; then
  skip_gate "Gate F4: bundled script" "build/Apple2Forge.app not present; run tools/60_build_app.sh first"
else
  pass_gate "Gate F4: bundled script" "${gate_start}"
fi

print_summary "PASSED"
exit 0
