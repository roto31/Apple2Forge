#!/bin/bash
set -euo pipefail

# Stage 2: prove the patched a2emu is a 64K machine that the MECC loader accepts.
# Boots the disk headless with a probe on the loader's milestones and checks
# that its memory-size byte ($03AD) reads $40 (64K) and that $3000 is reached.
# Exit codes: 0 success, 1 gate failed, 2 config error.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DEFAULT_DISK="${REPO_ROOT}/MECC-A170 Number Munchers v1.3 (4am crack)/MECC-A170 Number Munchers v1.3 (4am crack).dsk"
readonly DEFAULT_BINARY="${REPO_ROOT}/build/a2emu-norom/a2emu"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2plus.rom"
readonly BOOT_FRAMES=1200
readonly RUN_TIMEOUT_SECONDS=60
# MECC loader: $0912 runs after the memory check passes; $3000 is the game.
readonly AFTER_MEMORY_CHECK="0912"
readonly GAME_ENTRY="3000"
readonly MEMORY_SIZE_BYTE="03AD"
readonly REQUIRED_MEMORY_SIZE=$(( 0x40 ))
readonly RESULT_DIR="${REPO_ROOT}/work/_gate/stage2"
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/stage2_language_card.log"
SUMMARY_TITLE="Stage 2 Language Card check"
# shellcheck source=../tools/lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<'EOF'
Usage: tests/stage2_language_card.sh [--disk PATH] [--binary PATH]

Boots the MECC disk in the patched a2emu (headless) and checks the loader's
64K test passes and the game entry $3000 is reached.
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

mkdir -p "${LOG_DIR}" "${RESULT_DIR}"
echo "=== stage2_language_card.sh $(date '+%Y-%m-%d %H:%M:%S %z')" >> "${LOG_FILE}"

# ── Gate A: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate A] Inputs"
for needed in "${disk}" "${binary}" "${ROM_FILE}"; do
  if [[ ! -r "${needed}" ]]; then
    fail_gate "Gate A: Inputs" "${gate_start}" "Missing ${needed}. Build: tools/15_build_a2emu_norom.sh; ROM: tools/05_fetch_rom.sh." 2
  fi
done
pass_gate "Gate A: Inputs" "${gate_start}"

# ── Gate B: headless boot with milestone probe ──────────────────────
gate_start="$(date +%s)"
echo "[Gate B] Headless boot, ${BOOT_FRAMES} frames"
probe_script="${RESULT_DIR}/language_card.probe"
probe_out="${RESULT_DIR}/language_card.out"
cat > "${probe_script}" <<EOF
counter seen
probe milestone(site = pc) {
  inc seen
  if (seen < 20)
    printf("%04X %02X\n", site, peek8(\$${MEMORY_SIZE_BYTE}))
}
install milestone at \$${AFTER_MEMORY_CHECK}, \$${GAME_ENTRY}
EOF
rm -f "${probe_out}"
run_status=0
perl -e 'alarm shift; exec { $ARGV[0] } @ARGV' "${RUN_TIMEOUT_SECONDS}" "${binary}" --headless --no-sound \
  --frames="${BOOT_FRAMES}" --rom="${ROM_FILE}" --disk1="${disk}" \
  --probe="${probe_script}" --probe-out="${probe_out}" >>"${LOG_FILE}" 2>&1 || run_status=$?
if [[ "${run_status}" -ne 0 || ! -f "${probe_out}" ]]; then
  fail_gate "Gate B: Headless boot" "${gate_start}" "a2emu exited ${run_status} (142 = hung) or wrote no probe output."
fi
cat "${probe_out}" >> "${LOG_FILE}"
ARTIFACTS+=("work/_gate/stage2/language_card.out")
pass_gate "Gate B: Headless boot" "${gate_start}"

# ── Gate C: 64K accepted, game entered ──────────────────────────────
gate_start="$(date +%s)"
echo "[Gate C] Memory check passed and \$${GAME_ENTRY} reached"
memory_size_hex="$(awk -v site="${AFTER_MEMORY_CHECK}" '$1 == site { print $2; exit }' "${probe_out}")"
if [[ -z "${memory_size_hex}" ]]; then
  fail_gate "Gate C: 64K + entry" "${gate_start}" "\$${AFTER_MEMORY_CHECK} never ran: the loader stopped at its memory check. The Language Card patch is missing or broken; rebuild with tools/15_build_a2emu_norom.sh."
fi
if [[ $(( 0x${memory_size_hex} )) -lt "${REQUIRED_MEMORY_SIZE}" ]]; then
  fail_gate "Gate C: 64K + entry" "${gate_start}" "Loader measured \$${memory_size_hex}, needs \$40 (64K)."
fi
if ! grep -q "^${GAME_ENTRY} " "${probe_out}"; then
  fail_gate "Gate C: 64K + entry" "${gate_start}" "Memory check passed but \$${GAME_ENTRY} was not reached in ${BOOT_FRAMES} frames."
fi
echo "    memory size \$${memory_size_hex} (64K), \$${GAME_ENTRY} reached"
pass_gate "Gate C: 64K + entry" "${gate_start}"

print_artifacts
print_summary "PASSED"
