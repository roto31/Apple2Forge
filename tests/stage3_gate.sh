#!/bin/bash
set -euo pipefail

# Stage 3 gate: capture is complete and restorable.
#   G1  tools/30_capture.sh writes all four capture points at the right PCs
#   G2  the report has disk reads for every phase and the card-RAM game code
#   G3  the title capture restores and holds the title screen for 300 frames
#   G4  restoring the dosload capture (no keys) reaches $D1FE byte-identical to
#       the full boot: RAM, registers, Language Card and Disk II state
# Exit codes: 0 success, 1 gate failed, 2 config error.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DEFAULT_DISK="${REPO_ROOT}/MECC-A170 Number Munchers v1.3 (4am crack)/MECC-A170 Number Munchers v1.3 (4am crack).dsk"
readonly DEFAULT_BINARY="${REPO_ROOT}/build/a2emu-norom/a2emu"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2plus.rom"
readonly TOOLS_SRC="${REPO_ROOT}/tests/tools"
readonly TOOLS_BIN="${REPO_ROOT}/build/test-tools"
readonly RESULT_DIR="${REPO_ROOT}/work/_gate/stage3"
readonly CAPTURE_DIR="${RESULT_DIR}/capture"
readonly RUN_TIMEOUT_SECONDS=60
readonly TITLE_ADDRESS="1E95"
readonly GAME_START_ADDRESS="D1FE"
readonly HOLD_FRAMES=300
# The title loop passes $1E95 about 675 times a frame; half that over 300
# frames still proves it kept looping rather than stalling early.
readonly MIN_TITLE_LOOP_HITS=100000
readonly TITLE_TEXT="number munchers"
readonly REPLAY_FRAMES=600
readonly SNAPSHOT_SUFFIXES=("" ".regs" ".lc" ".disk")
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/stage3_gate.log"
SUMMARY_TITLE="Stage 3 gate"
# shellcheck source=../tools/lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<'EOF'
Usage: tests/stage3_gate.sh [--disk PATH] [--binary PATH]

Runs tools/30_capture.sh into work/_gate/stage3/capture, then checks the
captures (G1), the report (G2), the title restore (G3) and an exact replay of
the post-title disk load from a restore (G4).
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

mkdir -p "${LOG_DIR}" "${RESULT_DIR}" "${TOOLS_BIN}"
echo "=== stage3_gate.sh $(date '+%Y-%m-%d %H:%M:%S %z')" >> "${LOG_FILE}"

run_restored() {
  local frames="$1"; shift
  perl -e 'alarm shift; exec { $ARGV[0] } @ARGV' "${RUN_TIMEOUT_SECONDS}" "${binary}" --headless --no-sound \
    --frames="${frames}" --rom="${ROM_FILE}" --disk1="${disk}" "$@" >>"${LOG_FILE}" 2>&1
}

# ── Gate T: test tools ──────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate T] Test tools"
if [[ ! -x "${TOOLS_BIN}/ocr_text" || "${TOOLS_SRC}/ocr_text.swift" -nt "${TOOLS_BIN}/ocr_text" ]]; then
  if ! swiftc -O -o "${TOOLS_BIN}/ocr_text" "${TOOLS_SRC}/ocr_text.swift" >>"${LOG_FILE}" 2>&1; then
    fail_gate "Gate T: Test tools" "${gate_start}" "swiftc failed for tests/tools/ocr_text.swift; see log." 2
  fi
fi
pass_gate "Gate T: Test tools" "${gate_start}"

# ── G1: capture ─────────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[G1] Capture"
if ! "${REPO_ROOT}/tools/30_capture.sh" --disk "${disk}" --binary "${binary}" --out "${CAPTURE_DIR}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "G1: Capture" "${gate_start}" "tools/30_capture.sh failed; run it with --out ${CAPTURE_DIR} to see which gate."
fi
while read -r name address; do
  pc="$(awk '$1 == "pc" { print $2 }' "${CAPTURE_DIR}/${name}.regs")"
  if [[ "${pc}" != "${address}" ]]; then
    fail_gate "G1: Capture" "${gate_start}" "${name} was taken at \$${pc}, expected \$${address}."
  fi
done < "${CAPTURE_DIR}/points.txt"
echo "    $(wc -l < "${CAPTURE_DIR}/points.txt" | tr -d ' ') capture points at their addresses"
ARTIFACTS+=("work/_gate/stage3/capture/")
pass_gate "G1: Capture" "${gate_start}"

# ── G2: report content ──────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[G2] Report: disk reads per phase, card-RAM game code"
if ! report_check="$(python3 -I - "${CAPTURE_DIR}/capture.json" <<'PY' 2>&1
import json, sys
report = json.load(open(sys.argv[1]))
phases = {p["phase"]: p for p in report["disk_reads"]}
problems = [f"no sector reads in phase {n}" for n in (0, 1, 2) if phases.get(n, {}).get("sectors", 0) == 0]
if not any(r.startswith("$D") or r.startswith("$E") for r in phases.get(2, {}).get("destination_pages", [])):
    problems.append("title-to-game phase loads nothing into $D000-$FFFF")
gamestart = next(p for p in report["points"] if p["name"] == "gamestart")
if not gamestart["language_card"]["present"] or not gamestart["language_card"]["flags"]["read_ram"]:
    problems.append("gamestart does not read from card RAM")
if not any(g["code_bytes_D000_up_differing_from_rom"] > 0 for g in report["dependencies"]):
    problems.append("no executed card-RAM code found")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print(", ".join(f"phase {n}: {phases[n]['sectors']} sectors" for n in sorted(phases)))
PY
)"; then
  fail_gate "G2: Report" "${gate_start}" "${report_check}"
fi
echo "    ${report_check}"
pass_gate "G2: Report" "${gate_start}"

# ── G3: title restore holds ─────────────────────────────────────────
gate_start="$(date +%s)"
echo "[G3] Restore title, ${HOLD_FRAMES} frames"
cat > "${RESULT_DIR}/title_hold.probe" <<EOF
counter hits
probe title(site = pc) {
  inc hits
  if (hits == 1 || hits % 2000 == 0)
    printf("hit %u page2 %08X\n", hits, hash(\$4000, \$5FFF))
}
install title at \$${TITLE_ADDRESS}
EOF
rm -f "${RESULT_DIR}/title_hold.out"
run_status=0
run_restored "${HOLD_FRAMES}" --restore="${CAPTURE_DIR}/title" \
  --probe="${RESULT_DIR}/title_hold.probe" --probe-out="${RESULT_DIR}/title_hold.out" || run_status=$?
if [[ "${run_status}" -ne 0 || ! -s "${RESULT_DIR}/title_hold.out" ]]; then
  fail_gate "G3: Title restore" "${gate_start}" "Restored run exited ${run_status} (142 = hung) or never reached \$${TITLE_ADDRESS}."
fi
last_hit="$(awk 'END { print $2 }' "${RESULT_DIR}/title_hold.out")"
distinct_pages="$(awk '{ print $4 }' "${RESULT_DIR}/title_hold.out" | sort -u | wc -l | tr -d ' ')"
if [[ "${last_hit}" -lt "${MIN_TITLE_LOOP_HITS}" || "${distinct_pages}" -ne 1 ]]; then
  fail_gate "G3: Title restore" "${gate_start}" "Title loop ran ${last_hit} times (need ${MIN_TITLE_LOOP_HITS}) with ${distinct_pages} different hi-res page 2 hashes (need 1)."
fi
python3 -I "${TOOLS_SRC}/hgr_to_png.py" "${CAPTURE_DIR}/title" 2 "${RESULT_DIR}/title.png" 2 >>"${LOG_FILE}" 2>&1
title_ocr="$("${TOOLS_BIN}/ocr_text" "${RESULT_DIR}/title.png" 2>>"${LOG_FILE}" | tr '[:upper:]' '[:lower:]')"
echo "G3 OCR: ${title_ocr}" >> "${LOG_FILE}"
if [[ "${title_ocr}" != *"${TITLE_TEXT}"* ]]; then
  fail_gate "G3: Title restore" "${gate_start}" "Title capture does not read '${TITLE_TEXT}'; open work/_gate/stage3/title.png."
fi
echo "    title loop ran ${last_hit}+ times, page 2 unchanged, OCR '${TITLE_TEXT}'"
ARTIFACTS+=("work/_gate/stage3/title.png")
pass_gate "G3: Title restore" "${gate_start}"

# ── G4: exact replay of the post-title load ─────────────────────────
gate_start="$(date +%s)"
echo "[G4] Restore dosload, run to \$${GAME_START_ADDRESS}, compare with the full boot"
replay="${RESULT_DIR}/replay_gamestart"
for suffix in "${SNAPSHOT_SUFFIXES[@]}"; do rm -f "${replay}${suffix}"; done
run_status=0
run_restored "${REPLAY_FRAMES}" --restore="${CAPTURE_DIR}/dosload" \
  --snapshot-at="${GAME_START_ADDRESS}" --snapshot-out="${replay}" || run_status=$?
for suffix in "${SNAPSHOT_SUFFIXES[@]}"; do
  if ! cmp -s "${CAPTURE_DIR}/gamestart${suffix}" "${replay}${suffix}"; then
    diff "${CAPTURE_DIR}/gamestart.regs" "${replay}.regs" >> "${LOG_FILE}" 2>&1 || true
    fail_gate "G4: Exact replay" "${gate_start}" "gamestart${suffix} differs after restoring dosload (a2emu exit ${run_status}). Restore is missing machine state; see the .regs diff in the log."
  fi
done
echo "    RAM, registers, Language Card and Disk II state identical at \$${GAME_START_ADDRESS}"
pass_gate "G4: Exact replay" "${gate_start}"

print_artifacts
print_summary "PASSED"
