#!/bin/bash
set -euo pipefail

# Stage 6a gate: a2emu reads .dsk images saved in ProDOS sector order.
#   O1  A DOS-order disk and a ProDOS-order copy of it (rewritten here) boot to
#       byte-identical machine snapshots: the disk order is detected from the
#       DOS catalog chain and the image is nibblized the same way.
# Needs a downloaded library (or --disk=PATH to a DOS 3.3 .dsk) and the II+ ROM.
# Exit codes: 0 PASS, 1 gate failed, 2 config error.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly EMULATOR="${REPO_ROOT}/build/a2emu-norom/a2emu"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2plus.rom"
readonly DEFAULT_LIBRARY="${HOME}/Library/Application Support/Apple2Forge/library"
readonly OUT_DIR="${REPO_ROOT}/work/_gate/stage6"
readonly RUN_FRAMES=600
LOG_FILE="${OUT_DIR}/disk_order_gate.log"
SUMMARY_TITLE="Stage 6a disk sector-order gate"
# shellcheck source=../tools/lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  echo "Usage: tests/stage6_disk_order_gate.sh [--disk=PATH] [--library=DIR] [--help]"
}
DISK=""
LIBRARY="${DEFAULT_LIBRARY}"
for arg in "$@"; do
  case "${arg}" in
    --help|-h) usage; exit 0 ;;
    --disk=*) DISK="${arg#--disk=}" ;;
    --library=*) LIBRARY="${arg#--library=}" ;;
    *) echo "ERROR: unknown option ${arg}" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "${OUT_DIR}"
: > "${LOG_FILE}"
readonly PRODOS_COPY="${OUT_DIR}/prodos-order-copy.dsk"

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
for needed in "${EMULATOR}" "${ROM_FILE}"; do
  if [[ ! -f "${needed}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${needed}. Run tools/15_build_a2emu_norom.sh and tools/05_fetch_rom.sh." 2
  fi
done
# Picks a DOS 3.3 disk whose catalog links up in DOS order, then writes its
# ProDOS-order copy. Prints the chosen disk.
if ! DISK="$(python3 -I - "${DISK}" "${LIBRARY}/disks" "${PRODOS_COPY}" <<'PY' 2>> "${LOG_FILE}"
import os, sys
SECTOR, TRACK = 256, 4096
def po_index(s): return s if s in (0, 15) else 15 - s
def chain(img):
    vtoc = img[17 * TRACK:17 * TRACK + SECTOR]
    if vtoc[0x27] != 122: return 0
    t, s, n = vtoc[1], vtoc[2], 0
    while 0 < t < 35 and s < 16 and n < 32:
        c = img[(t * 16 + s) * SECTOR:]
        t, s, n = c[1], c[2], n + 1
    return n
wanted, folder, out = sys.argv[1:]
candidates = [wanted] if wanted else sorted(
    os.path.join(folder, f) for f in os.listdir(folder) if f.lower().endswith(".dsk"))
for path in candidates:
    img = open(path, "rb").read()
    if len(img) == 35 * TRACK and chain(img) >= 3:
        copy = bytearray(len(img))
        for t in range(35):
            for s in range(16):
                src = (t * 16 + s) * SECTOR
                dst = (t * 16 + po_index(s)) * SECTOR
                copy[dst:dst + SECTOR] = img[src:src + SECTOR]
        open(out, "wb").write(copy)
        print(path)
        sys.exit(0)
sys.exit("no DOS 3.3 .dsk with a catalog chain found")
PY
)"; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "No usable DOS 3.3 disk; pass --disk=PATH or download the library." 2
fi
echo "  disk: ${DISK}" | tee -a "${LOG_FILE}"
pass_gate "Gate 0: Inputs" "${gate_start}"

# ── Gate O1: both orders boot the same ──────────────────────────────
gate_start="$(date +%s)"
echo "[Gate O1] DOS-order disk and ProDOS-order copy boot identically"
boot_snapshot() {
  local disk="$1" out="$2"
  rm -f "${out}" "${out}".*
  "${EMULATOR}" --headless --no-sound --frames="${RUN_FRAMES}" --rom="${ROM_FILE}" --disk1="${disk}" \
    --snapshot-frame="${RUN_FRAMES}" --snapshot-out="${out}" >> "${LOG_FILE}" 2>&1 || true
  [[ -f "${out}" ]]
}
if ! boot_snapshot "${DISK}" "${OUT_DIR}/dos-order.snap" \
  || ! boot_snapshot "${PRODOS_COPY}" "${OUT_DIR}/prodos-order.snap"; then
  fail_gate "Gate O1: Disk order" "${gate_start}" "A boot wrote no snapshot; see ${LOG_FILE}."
fi
if ! cmp -s "${OUT_DIR}/dos-order.snap" "${OUT_DIR}/prodos-order.snap" \
  || ! cmp -s "${OUT_DIR}/dos-order.snap.regs" "${OUT_DIR}/prodos-order.snap.regs"; then
  fail_gate "Gate O1: Disk order" "${gate_start}" "The ProDOS-order copy booted differently from the original."
fi
pass_gate "Gate O1: Disk order" "${gate_start}"

print_summary "PASSED"
