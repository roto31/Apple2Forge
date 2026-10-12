#!/bin/bash
set -euo pipefail

# Stage 6a gate: a2emu --control-fd changes disks while the machine runs.
#   S1  Boot with drive 1 empty (the Disk II boot ROM spins), mount disk A
#       through the control pipe mid-run: the machine boots it, reaching $0801
#       with disk A's first sector at $0800.
#   S2  Bad commands are reported and ignored; eject and drive-2 mounts are
#       applied; the run still finishes its frames (exit 0).
# Uses two images from the downloaded library (never committed).
# Exit codes: 0 PASS, 1 gate failed, 2 config error.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly EMULATOR="${REPO_ROOT}/build/a2emu-norom/a2emu"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2plus.rom"
readonly LIBRARY="${A2N_LIBRARY:-${HOME}/Library/Application Support/Apple2Forge/library}"
readonly OUT_DIR="${REPO_ROOT}/work/_gate/stage6"
# About 10 s headless; the mount is sent 0.5 s in, thousands of frames after boot.
readonly RUN_FRAMES=150000
readonly MOUNT_DELAY_SECONDS=0.5
readonly SECTOR_BYTES=256
readonly BOOT_SECTOR_ADDR=$(( 0x0800 ))
LOG_FILE="${OUT_DIR}/disk_swap.log"
SUMMARY_TITLE="Stage 6a disk swap gate"
# shellcheck source=../tools/lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  echo "Usage: tests/stage6_disk_swap.sh [--help]   (A2N_LIBRARY=DIR overrides the library folder)"
}
for arg in "$@"; do
  case "${arg}" in
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option ${arg}" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "${OUT_DIR}"
: > "${LOG_FILE}"

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
for needed in "${EMULATOR}" "${ROM_FILE}" "${LIBRARY}/manifest.json"; do
  if [[ ! -e "${needed}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${needed}. Build: tools/15_build_a2emu_norom.sh; library: tools/07_fetch_edu_library.sh." 2
  fi
done
disk_list="$(python3 -I - "${LIBRARY}" <<'PY'
import json, os, sys
library = sys.argv[1]
files = json.load(open(os.path.join(library, "manifest.json")))["files"]
seen, picked = set(), []
for entry in files:
    path = os.path.join(library, "disks", entry["path"])
    first = open(path, "rb").read(256)
    if first not in seen:
        seen.add(first)
        picked.append(path)
    if len(picked) == 2:
        break
print("\n".join(picked))
PY
)"
DISK_A="$(echo "${disk_list}" | sed -n 1p)"
DISK_B="$(echo "${disk_list}" | sed -n 2p)"
if [[ -z "${DISK_B}" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "Need two library images with different boot sectors." 2
fi
echo "    disk A: ${DISK_A##*/}"
echo "    disk B: ${DISK_B##*/}"
pass_gate "Gate 0: Inputs" "${gate_start}"

# ── Run: one emulator, commands fed through a FIFO ──────────────────
fifo="${OUT_DIR}/control.fifo"
snapshot="${OUT_DIR}/swap.snap"
rm -f "${fifo}" "${snapshot}" "${snapshot}".*
mkfifo "${fifo}"
{
  sleep "${MOUNT_DELAY_SECONDS}"
  echo "mount 1 ${DISK_A}"
  sleep 0.2
  echo "frobnicate 1"
  echo "mount 3 ${DISK_B}"
  echo "mount 2 ${OUT_DIR}/does-not-exist.dsk"
  echo "eject 2"
  echo "mount 2 ${DISK_B}"
} > "${fifo}" &
writer_pid=$!
run_status=0
# Drive 2 holds disk B from the start so the slot 6 boot ROM is present while
# drive 1 is empty.
"${EMULATOR}" --headless --no-sound --frames="${RUN_FRAMES}" --rom="${ROM_FILE}" \
  --disk2="${DISK_B}" --control-fd=3 --snapshot-at=0801 --snapshot-out="${snapshot}" \
  3<"${fifo}" 2>&1 | grep -v "Unsupported IO location" >> "${LOG_FILE}" || run_status=$?
wait "${writer_pid}" || true
rm -f "${fifo}"

# ── Gate S1: mid-run mount boots the new disk ───────────────────────
gate_start="$(date +%s)"
echo "[Gate S1] Mid-run mount in drive 1 boots that disk"
mount_frame="$(sed -n 's/^control: \[frame \([0-9]*\)\] drive 1 now holds .*/\1/p' "${LOG_FILE}" | head -1)"
if [[ -z "${mount_frame}" ]] || [[ "${mount_frame}" -eq 0 ]]; then
  fail_gate "Gate S1: Mid-run mount" "${gate_start}" "No 'drive 1 now holds' message after frame 0; the control pipe was not read."
fi
if [[ ! -f "${snapshot}" ]]; then
  fail_gate "Gate S1: Mid-run mount" "${gate_start}" "The machine never reached \$0801 after the mount at frame ${mount_frame}."
fi
if ! python3 -I - "${snapshot}" "${DISK_A}" "${BOOT_SECTOR_ADDR}" "${SECTOR_BYTES}" <<'PY' >> "${LOG_FILE}" 2>&1
import sys
ram = open(sys.argv[1], "rb").read()
disk = open(sys.argv[2], "rb").read()
addr, size = int(sys.argv[3]), int(sys.argv[4])
same = ram[addr:addr + size] == disk[:size]
print(f"boot sector at $0800 {'matches' if same else 'DIFFERS from'} disk A sector 0")
sys.exit(0 if same else 1)
PY
then
  fail_gate "Gate S1: Mid-run mount" "${gate_start}" "\$0800 does not hold disk A's boot sector; the wrong image was read."
fi
echo "    mounted at frame ${mount_frame}; \$0800 holds disk A's boot sector"
pass_gate "Gate S1: Mid-run mount" "${gate_start}"

# ── Gate S2: errors reported, eject and drive 2 applied, run finishes ─
gate_start="$(date +%s)"
echo "[Gate S2] Bad commands ignored; eject and drive 2 applied"
expected_lines=(
  'control: ignored "frobnicate 1"'
  'control: ignored "mount 3 '
  'control: cannot open .*does-not-exist.dsk'
  'control: \[frame [0-9]*\] drive 2 is empty'
  'control: \[frame [0-9]*\] drive 2 now holds '
)
for pattern in "${expected_lines[@]}"; do
  if ! grep -q "${pattern}" "${LOG_FILE}"; then
    fail_gate "Gate S2: Commands" "${gate_start}" "Expected a line matching '${pattern}' in ${LOG_FILE#"${REPO_ROOT}"/}."
  fi
done
if [[ "${run_status}" -ne 0 ]]; then
  fail_gate "Gate S2: Commands" "${gate_start}" "The emulator exited ${run_status} instead of finishing its frames."
fi
pass_gate "Gate S2: Commands" "${gate_start}"

rm -f "${snapshot}" "${snapshot}".*
print_summary "PASSED"
