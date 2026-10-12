#!/bin/bash
set -euo pipefail

# Stage 3 capture: run the user's disk headless in the patched a2emu, walking
# from boot into the first game with a fixed key file, and save the machine at
# four points (RAM, registers, Language Card, Disk II state). Then log every
# sector the loader reads, collect the executed code, and write a report.
# Output stays under work/ (Git-ignored): it contains copyrighted game bytes.
# Exit codes: 0 success, 1 gate failed, 2 config error, 3 missing dependency.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DEFAULT_DISK="${REPO_ROOT}/MECC-A170 Number Munchers v1.3 (4am crack)/MECC-A170 Number Munchers v1.3 (4am crack).dsk"
readonly DEFAULT_BINARY="${REPO_ROOT}/build/a2emu-norom/a2emu"
readonly DEFAULT_KEYS="${REPO_ROOT}/tests/fixtures/stage3_walk.keys"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2plus.rom"
readonly REPORT_TOOL="${REPO_ROOT}/tools/lib/capture_report.py"
readonly WALK_FRAMES=1800
readonly RUN_TIMEOUT_SECONDS=120
# Capture points, in the order the walk reaches them:
#   entry3000  MECC loader hands over to the game
#   title      title screen key wait
#   dosload    DOS entry the game calls after the last menu key, before the
#              post-title disk load (restoring here replays exactly; see G4)
#   gamestart  first instruction of the game code loaded into card RAM
readonly CAPTURE_NAMES=(entry3000 title dosload gamestart)
readonly CAPTURE_ADDRESSES=(3000 1E95 03D9 D1FE)
readonly SNAPSHOT_SUFFIXES=("" ".regs" ".lc" ".disk")
# $BBF4: the loader's sector-data reader. The address field it just matched is
# at $B9C8 (sector) / $B9C9 (track); the destination pointer is in $2E/$2F.
readonly SECTOR_READER="BBF4"
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/30_capture.log"
SUMMARY_TITLE="Stage 3 capture"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<'EOF'
Usage: tools/30_capture.sh [--disk PATH] [--binary PATH] [--keys PATH] [--out DIR] [--dry-run]

Captures the machine at $3000 (entry3000), $1E95 (title), $03D9 (dosload) and
$D1FE (gamestart), logs disk sector reads by phase, collects executed code, and
writes capture.json / capture.md. Output is personal-use analysis of your own
disk and stays under work/.
  --disk PATH     default: the Number Munchers .dsk in the repo root folder
  --binary PATH   default: build/a2emu-norom/a2emu
  --keys PATH     default: tests/fixtures/stage3_walk.keys
  --out DIR       default: work/<disk-slug>/capture
  --dry-run       show what would run; change nothing
EOF
}

disk="${DEFAULT_DISK}"
binary="${DEFAULT_BINARY}"
keys="${DEFAULT_KEYS}"
out_dir=""
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --disk) disk="${2:?--disk needs a path}"; shift 2 ;;
    --binary) binary="${2:?--binary needs a path}"; shift 2 ;;
    --keys) keys="${2:?--keys needs a path}"; shift 2 ;;
    --out) out_dir="${2:?--out needs a folder}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ -z "${out_dir}" ]]; then
  out_dir="${REPO_ROOT}/work/$(disk_slug "${disk}")/capture"
fi

if [[ "${dry_run}" -eq 1 ]]; then
  echo "Would capture ${CAPTURE_NAMES[*]} (at ${CAPTURE_ADDRESSES[*]}) from ${disk}"
  echo "  emulator ${binary}, keys ${keys}, ${WALK_FRAMES} frames, output ${out_dir}"
  exit 0
fi

mkdir -p "${LOG_DIR}"
echo "=== 30_capture.sh $(date '+%Y-%m-%d %H:%M:%S %z') disk=${disk} out=${out_dir}" >> "${LOG_FILE}"

run_emulator() {
  perl -e 'alarm shift; exec { $ARGV[0] } @ARGV' "${RUN_TIMEOUT_SECONDS}" "${binary}" --headless --no-sound \
    --frames="${WALK_FRAMES}" --rom="${ROM_FILE}" --disk1="${disk}" --key-file="${keys}" "$@" >>"${LOG_FILE}" 2>&1
}

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
for needed in "${disk}" "${binary}" "${keys}" "${ROM_FILE}" "${REPORT_TOOL}"; do
  if [[ ! -r "${needed}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${needed}. Build: tools/15_build_a2emu_norom.sh; ROM: tools/05_fetch_rom.sh --install." 2
  fi
done
if ! command -v python3 >/dev/null; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "python3 not found." 3
fi
if ! "${binary}" --help 2>&1 | grep -q -- "--restore="; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "${binary} has no --restore; rebuild with tools/15_build_a2emu_norom.sh (Language Card snapshot patch)." 2
fi
rm -rf "${out_dir}"
mkdir -p "${out_dir}"
pass_gate "Gate 0: Inputs" "${gate_start}"

# ── Gate 1: snapshots ───────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 1] Snapshots at ${CAPTURE_ADDRESSES[*]}"
: > "${out_dir}/points.txt"
for i in "${!CAPTURE_NAMES[@]}"; do
  name="${CAPTURE_NAMES[$i]}"
  address="${CAPTURE_ADDRESSES[$i]}"
  run_status=0
  run_emulator --snapshot-at="${address}" --snapshot-out="${out_dir}/${name}" || run_status=$?
  for suffix in "${SNAPSHOT_SUFFIXES[@]}"; do
    if [[ ! -f "${out_dir}/${name}${suffix}" ]]; then
      fail_gate "Gate 1: Snapshots" "${gate_start}" "${name}: \$${address} not reached in ${WALK_FRAMES} frames, or ${name}${suffix} not written (a2emu exit ${run_status}; 142 = hung). Check the key file timing."
    fi
  done
  echo "${name} ${address}" >> "${out_dir}/points.txt"
  echo "    ${name}: pc \$$(awk '$1 == "pc" { print $2 }' "${out_dir}/${name}.regs"), cycle $(awk '$1 == "cycles" { print $2 }' "${out_dir}/${name}.regs")"
done
ARTIFACTS+=("${out_dir}/{$(IFS=,; echo "${CAPTURE_NAMES[*]}")}{,.regs,.lc,.disk}")
pass_gate "Gate 1: Snapshots" "${gate_start}"

# ── Gate 2: sector reads by phase ───────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 2] Sector reads at \$${SECTOR_READER}"
cat > "${out_dir}/sectors.probe" <<EOF
counter phase
counter sectors

probe sector(site = pc) {
  inc sectors
  printf("sector %u phase %u track %u sector %u buffer %04X\n", sectors, phase, peek8(\$B9C9), peek8(\$B9C8), peek16(\$2E))
}

probe marker(site = pc) {
  if (site == \$${CAPTURE_ADDRESSES[0]} && phase == 0) { phase = 1  printf("phase 1 at \$${CAPTURE_ADDRESSES[0]} after %u sectors\n", sectors) }
  if (site == \$${CAPTURE_ADDRESSES[1]} && phase == 1) { phase = 2  printf("phase 2 at \$${CAPTURE_ADDRESSES[1]} after %u sectors\n", sectors) }
  if (site == \$${CAPTURE_ADDRESSES[3]} && phase == 2) { phase = 3  printf("phase 3 at \$${CAPTURE_ADDRESSES[3]} after %u sectors\n", sectors) }
}

install sector at \$${SECTOR_READER}
install marker at \$${CAPTURE_ADDRESSES[0]}, \$${CAPTURE_ADDRESSES[1]}, \$${CAPTURE_ADDRESSES[3]}
EOF
run_status=0
run_emulator --probe="${out_dir}/sectors.probe" --probe-out="${out_dir}/sectors.out" || run_status=$?
if [[ "${run_status}" -ne 0 ]] || ! grep -q "^phase 3 " "${out_dir}/sectors.out" 2>/dev/null; then
  fail_gate "Gate 2: Sector reads" "${gate_start}" "Probe run exited ${run_status} or never reached \$${CAPTURE_ADDRESSES[3]}; see ${out_dir}/sectors.out."
fi
echo "    $(grep -c '^sector ' "${out_dir}/sectors.out") sectors; $(grep '^phase' "${out_dir}/sectors.out" | sort -u | tr '\n' ';')"
ARTIFACTS+=("${out_dir}/sectors.out")
pass_gate "Gate 2: Sector reads" "${gate_start}"

# ── Gate 3: executed code ───────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 3] Collect executed code"
run_status=0
run_emulator --collect --from-rom --out="${out_dir}/collect.json" || run_status=$?
if [[ "${run_status}" -ne 0 || ! -s "${out_dir}/collect.json" ]]; then
  fail_gate "Gate 3: Collect" "${gate_start}" "a2emu --collect exited ${run_status} or wrote nothing."
fi
ARTIFACTS+=("${out_dir}/collect.json")
pass_gate "Gate 3: Collect" "${gate_start}"

# ── Gate 4: report ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 4] Report"
if ! python3 -I "${REPORT_TOOL}" "${out_dir}" "${ROM_FILE}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 4: Report" "${gate_start}" "tools/lib/capture_report.py failed; see log."
fi
ARTIFACTS+=("${out_dir}/capture.json" "${out_dir}/capture.md")
pass_gate "Gate 4: Report" "${gate_start}"

print_artifacts
print_summary "PASSED"
