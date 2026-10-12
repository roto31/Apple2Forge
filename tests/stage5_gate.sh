#!/bin/bash
set -euo pipefail

# Stage 5 gate: is the T2-hybrid app real, ROM-free, and the same game?
#   G0  build: tools/50_recompile.sh (its own equivalence + random-key gates)
#       and tools/55_wrap_t2.sh
#   G1  no ROM: tier label, signature, no Apple ROM / Disk II PROM bytes in any
#       bundle file, and start image + the ROM blocks it lists == the title
#       snapshot (only ROM bytes and I/O were left out)
#   G2  native share: no recorded-session instruction ran uncompiled and the
#       lowest native share is at least MIN_NATIVE_PERCENT
#   G3  equivalence: every recorded and random-key session equivalent to a2emu
#   G4  levels: each of the six game modes cleared at least MIN_LEVELS levels
#       in a session that is equivalent
#   G5  app: the bundle's launcher replays level sessions headless (with and
#       without a user ROM) frame-identical to a2emu; a real launch opens a
#       window that is still running at STILL_RUNNING_AFTER_SECONDS
#   G6  regression: Stage 2 (--skip-launch), Stage 3 and Stage 4 gates
# Exit codes: 0 all levels passed, 1 a level failed, 2 config error.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DEFAULT_DISK="${REPO_ROOT}/MECC-A170 Number Munchers v1.3 (4am crack)/MECC-A170 Number Munchers v1.3 (4am crack).dsk"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2plus.rom"
readonly DISK2_SOURCE="${REPO_ROOT}/vendor/apple2tc-norom-src/lib/a2io/disk2.c"
readonly LIB="${REPO_ROOT}/tools/lib"
readonly TOOLS_BIN="${REPO_ROOT}/build/test-tools"
readonly RESULT_DIR="${REPO_ROOT}/work/_gate/stage5/gate"
readonly MIN_NATIVE_PERCENT=99
readonly MIN_LEVELS=4
readonly GAME_MODES="multiples factors primes equality inequality computer-decides"
# Replayed through the bundle: one with no ROM installed, one with it.
readonly APP_SESSION_NO_ROM="levels-primes"
readonly APP_SESSION_WITH_ROM="levels-equality"
readonly SESSION_FRAMES_LIMIT=400000
readonly WINDOWED_FRAMES=1200
readonly STILL_RUNNING_AFTER_SECONDS=10
readonly WINDOW_WAIT_SECONDS=10
readonly WINDOWED_RUN_LIMIT_SECONDS=60
readonly SCREENSHOT_TEXT=("number munchers")
readonly SCREENSHOT_ATTEMPTS=3
readonly SCREENSHOT_RETRY_SECONDS=2
readonly RUN_TIMEOUT_SECONDS=300
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/stage5_gate.log"
SUMMARY_TITLE="Stage 5 gate (T2-hybrid app)"
# shellcheck source=../tools/lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<'EOF'
Usage: tests/stage5_gate.sh [--disk PATH] [--jobs N] [--reuse] [--skip-launch]

  --disk PATH     default: the Number Munchers 4am crack .dsk in the repo
  --jobs N        parallel jobs for tools/50_recompile.sh (default 8)
  --reuse         G0: keep the existing recompile output; only re-wrap the app
  --skip-launch   G5: skip the real windowed launch (~20 s window)
EOF
}

disk="${DEFAULT_DISK}"
jobs=8
reuse=0
skip_launch=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --disk) disk="${2:?--disk needs a path}"; shift 2 ;;
    --jobs) jobs="${2:?--jobs needs a number}"; shift 2 ;;
    --reuse) reuse=1; shift ;;
    --skip-launch) skip_launch=1; shift ;;
    *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

work="${REPO_ROOT}/work/$(disk_slug "${disk}")"
build="${work}/t2build"
app="${work}/t2/$(basename "${disk}" | sed -E 's/\.[^.]+$//') (T2-hybrid).app"
contents="${app}/Contents"
mkdir -p "${LOG_DIR}" "${RESULT_DIR}"
echo "=== stage5_gate.sh $(date '+%Y-%m-%d %H:%M:%S %z') disk=${disk}" >> "${LOG_FILE}"

run_limited() {
  local seconds="$1"; shift
  perl -e 'alarm shift; exec { $ARGV[0] } @ARGV' "${seconds}" "$@"
}

# check_reports PYTHON_CHECK → runs it with argv = recorded report, random-key
# report, coverage sessions dir; prints its result line.
check_reports() {
  python3 -I - "${build}/equivalence/equivalence.json" "${build}/fuzz/equivalence/equivalence.json" \
    "${work}/coverage/sessions" "${GAME_MODES}" "${MIN_NATIVE_PERCENT}" "${MIN_LEVELS}" <<<"$1"
}

# ── G0: build ───────────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[G0] Build: recompile + equivalence, then wrap the app"
if [[ "${reuse}" -eq 0 ]] && ! "${REPO_ROOT}/tools/50_recompile.sh" --disk "${disk}" --jobs "${jobs}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "G0: Build" "${gate_start}" "tools/50_recompile.sh failed; its summary is at the end of ${LOG_FILE#"${REPO_ROOT}"/}."
fi
if ! "${REPO_ROOT}/tools/55_wrap_t2.sh" --disk "${disk}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "G0: Build" "${gate_start}" "tools/55_wrap_t2.sh failed; its summary is at the end of ${LOG_FILE#"${REPO_ROOT}"/}."
fi
echo "    ${app#"${REPO_ROOT}"/}"
pass_gate "G0: Build" "${gate_start}"

# ── G1: no ROM ──────────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[G1] No Apple ROM or Disk II PROM; start image is the title minus ROM and I/O"
tier="$(/usr/libexec/PlistBuddy -c 'Print :A2NTier' "${contents}/Info.plist" 2>/dev/null || true)"
if [[ "${tier}" != "T2-hybrid" ]]; then
  fail_gate "G1: No ROM" "${gate_start}" "Info.plist A2NTier is '${tier}', expected T2-hybrid."
fi
if ! codesign --verify --strict --deep "${app}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "G1: No ROM" "${gate_start}" "codesign --verify --strict failed for the app."
fi
if ! grep -q "DO NOT DISTRIBUTE" "${contents}/Resources/NOTICE.txt"; then
  fail_gate "G1: No ROM" "${gate_start}" "Personal-use notice missing from the bundle."
fi
scanned=0
while IFS= read -r -d '' file; do
  if [[ "${file}" == "${contents}/Resources/disk.dsk" ]]; then continue; fi
  if ! python3 -I "${LIB}/t2_romscan.py" "${file}" "${ROM_FILE}" "${DISK2_SOURCE}" >>"${LOG_FILE}" 2>&1; then
    fail_gate "G1: No ROM" "${gate_start}" "ROM or PROM bytes in ${file#"${app}"/}; see log."
  fi
  scanned=$(( scanned + 1 ))
done < <(find "${app}" -type f -print0)
if ! result="$(python3 -I - "${contents}/Resources/start/start" "${build}/title/title" "${ROM_FILE}" <<'PY' 2>&1
import sys
start, title, rom = sys.argv[1], sys.argv[2], open(sys.argv[3], "rb").read()
ROM_BASE, BLOCK, LC_HEADER, LC_BANK = 0xD000, 0x100, 8, 0x1000
ram, lc = bytearray(open(start, "rb").read()), bytearray(open(start + ".lc", "rb").read())
for line in open(start + ".blanked"):
    area, hexaddr = line.split()
    addr = int(hexaddr, 16)
    offset = {"ram": addr, "lc_bank1": LC_HEADER + addr - ROM_BASE,
              "lc_bank2": LC_HEADER + LC_BANK + addr - ROM_BASE,
              "lc_high": LC_HEADER + LC_BANK + addr - ROM_BASE}[area]
    target = ram if area == "ram" else lc
    target[offset:offset + BLOCK] = rom[addr - ROM_BASE:addr - ROM_BASE + BLOCK]
title_ram, title_lc = open(title, "rb").read(), open(title + ".lc", "rb").read()
ram_diff = [a for a in range(0x10000) if not 0xC000 <= a < 0xD000 and ram[a] != title_ram[a]]
lc_diff = sum(1 for a, b in zip(lc, title_lc) if a != b) + abs(len(lc) - len(title_lc))
if ram_diff or lc_diff:
    sys.exit(f"start + ROM refill differs from the title snapshot: {len(ram_diff)} RAM bytes "
             f"(first ${ram_diff[0] if ram_diff else 0:04X}), {lc_diff} Language Card bytes")
print("start image + ROM refill == title snapshot outside $C000-$CFFF")
PY
)"; then
  fail_gate "G1: No ROM" "${gate_start}" "${result}"
fi
echo "    tier T2-hybrid, signature valid, notice present, ${scanned} bundle files scanned clean"
echo "    ${result}"
pass_gate "G1: No ROM" "${gate_start}"

# ── G2: native share ────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[G2] Native share"
if ! result="$(check_reports '
import json, sys
recorded, fuzz = (json.load(open(p))["total"] for p in sys.argv[1:3])
floor = float(sys.argv[5])
recorded_low, fuzz_low = recorded["min_native_percent"], fuzz["min_native_percent"]
uncompiled, unrecorded = recorded["uncompiled"], fuzz["uncompiled"]
problems = []
if uncompiled:
    problems.append(f"{uncompiled} recorded-session instructions ran uncompiled")
if min(recorded_low, fuzz_low) < floor:
    problems.append(f"lowest native share {min(recorded_low, fuzz_low)}% < {floor}%")
print("; ".join(problems) if problems else
      f"recorded sessions: 0 uncompiled, lowest {recorded_low}% native; random-key sessions: "
      f"lowest {fuzz_low}% native (interpreter ran {unrecorded} unrecorded instructions)")
sys.exit(1 if problems else 0)
' 2>&1)"; then
  fail_gate "G2: Native share" "${gate_start}" "${result}"
fi
echo "    ${result}"
pass_gate "G2: Native share" "${gate_start}"

# ── G3: equivalence ─────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[G3] Every session equivalent to a2emu"
if ! result="$(check_reports '
import json, sys
lines, bad = [], []
for label, path in (("recorded", sys.argv[1]), ("random-key", sys.argv[2])):
    report = json.load(open(path))
    bad += [s["session"] for s in report["sessions"] if not s["equivalent"]]
    good, count, frames = (report["total"][k] for k in ("equivalent", "sessions", "frames"))
    quits = sum(1 for s in report["sessions"] if s.get("restarts"))
    lines.append(f"{label} {good}/{count} over {frames} frames" + (f" ({quits} quit and restarted)" if quits else ""))
print(f"not equivalent: {bad}" if bad else "; ".join(lines))
sys.exit(1 if bad else 0)
' 2>&1)"; then
  fail_gate "G3: Equivalence" "${gate_start}" "${result}"
fi
echo "    ${result}"
pass_gate "G3: Equivalence" "${gate_start}"

# ── G4: levels in every game mode ───────────────────────────────────
gate_start="$(date +%s)"
echo "[G4] At least ${MIN_LEVELS} levels cleared in each game mode, natively equivalent"
if ! result="$(check_reports '
import json, sys
from pathlib import Path
equivalent = {s["session"]: s["equivalent"] for s in json.load(open(sys.argv[1]))["sessions"]}
need = int(sys.argv[6])
cleared, bad = [], []
for mode in sys.argv[4].split():
    name = f"levels-{mode}"
    path = Path(sys.argv[3]) / name / "session.json"
    levels = (json.load(open(path)).get("levels") or {}).get("levels_cleared", 0) if path.exists() else 0
    cleared.append(f"{mode} {levels}")
    if levels < need or not equivalent.get(name):
        bad.append(f"{name}: {levels} levels, equivalent={equivalent.get(name)}")
print(f"short: {bad}" if bad else "levels cleared: " + ", ".join(cleared))
sys.exit(1 if bad else 0)
' 2>&1)"; then
  fail_gate "G4: Levels" "${gate_start}" "${result}"
fi
echo "    ${result}"
pass_gate "G4: Levels" "${gate_start}"

# ── G5: the app itself ──────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[G5] App: bundled replay (no ROM, then user ROM) and real launch"
empty_home="${RESULT_DIR}/empty-home"
rm -rf "${empty_home}"
mkdir -p "${empty_home}"
replay_through_app() {
  local session="$1" home="$2" tag="$3"
  local equiv="${build}/equivalence/${session}"
  rm -f "${RESULT_DIR}/${tag}.hash" "${RESULT_DIR}/${tag}.out"
  HOME="${home}" A2N_SUPPRESS_ALERT=1 run_limited "${RUN_TIMEOUT_SECONDS}" "${contents}/MacOS/launcher" \
    --headless --no-sound --frames="${SESSION_FRAMES_LIMIT}" \
    --key-file="${work}/coverage/sessions/${session}/session.keys" --probe="${equiv}/restored.probe" \
    --probe-out="${RESULT_DIR}/${tag}.out" --hash-frames="${RESULT_DIR}/${tag}.hash" >>"${LOG_FILE}" 2>&1 || true
  if [[ ! -s "${RESULT_DIR}/${tag}.hash" ]] || ! cmp -s "${RESULT_DIR}/${tag}.hash" "${equiv}/ref.hash"; then
    fail_gate "G5: App" "${gate_start}" "Bundled replay of ${session} (${tag}) differs from a2emu: compare ${RESULT_DIR#"${REPO_ROOT}"/}/${tag}.hash with ${equiv#"${REPO_ROOT}"/}/ref.hash."
  fi
  echo "    ${session} via the app (${tag}): $(wc -l < "${equiv}/ref.hash" | tr -d ' ') frames identical to a2emu"
}
replay_through_app "${APP_SESSION_NO_ROM}" "${empty_home}" "app-no-rom"
replay_through_app "${APP_SESSION_WITH_ROM}" "${HOME}" "app-user-rom"
if [[ "${skip_launch}" -eq 1 ]]; then
  echo "    real launch SKIPPED (--skip-launch)"
else
  # pgrep -f takes a regex; the app name has parentheses and dots.
  engine_pattern="$(printf '%s' "${app#"${REPO_ROOT}"/work/}/Contents/MacOS/a2n-t2" | sed 's/[][\.*^$()+?{}|]/\\&/g')"
  if pgrep -f "${engine_pattern}" >/dev/null; then
    fail_gate "G5: App" "${gate_start}" "The app is already running; quit it and re-run the gate." 2
  fi
  launch_time="$(date +%s)"
  open -n "${app}" --args --no-sound --frames="${WINDOWED_FRAMES}"
  pid=""
  window_info=""
  for _ in $(seq "${WINDOW_WAIT_SECONDS}"); do
    sleep 1
    pid="$(pgrep -f "${engine_pattern}" | head -n 1 || true)"
    if [[ -n "${pid}" ]]; then
      window_info="$("${TOOLS_BIN}/window_list" "${pid}" 2>/dev/null || true)"
      if [[ -n "${window_info}" ]]; then break; fi
    fi
  done
  if [[ -z "${pid}" || -z "${window_info}" ]]; then
    fail_gate "G5: App" "${gate_start}" "No window within ${WINDOW_WAIT_SECONDS}s (pid='${pid}'). Check ~/Library/Logs/Apple2Forge/."
  fi
  echo "    pid ${pid}, window ${window_info}"
  sleep $(( STILL_RUNNING_AFTER_SECONDS - ($(date +%s) - launch_time) > 0 ? STILL_RUNNING_AFTER_SECONDS - ($(date +%s) - launch_time) : 0 ))
  if ! kill -0 "${pid}" 2>/dev/null; then
    fail_gate "G5: App" "${gate_start}" "The app quit before ${STILL_RUNNING_AFTER_SECONDS}s. See ~/Library/Logs/Apple2Forge/."
  fi
  echo "    still running at ${STILL_RUNNING_AFTER_SECONDS}s"
  window_id="${window_info%% *}"
  screenshot_state="refused"
  for _ in $(seq "${SCREENSHOT_ATTEMPTS}"); do
    rm -f "${RESULT_DIR}/window.png"
    if ! screencapture -x -o -l "${window_id}" "${RESULT_DIR}/window.png" >>"${LOG_FILE}" 2>&1 \
      || [[ ! -s "${RESULT_DIR}/window.png" ]]; then
      break
    fi
    screenshot_state="no-text"
    text="$("${TOOLS_BIN}/ocr_text" "${RESULT_DIR}/window.png" 2>>"${LOG_FILE}" | tr '[:upper:]' '[:lower:]')"
    echo "OCR window: $(echo "${text}" | tr '\n' '|')" >> "${LOG_FILE}"
    if [[ "${text}" == *"${SCREENSHOT_TEXT[0]}"* ]]; then screenshot_state="ok"; break; fi
    sleep "${SCREENSHOT_RETRY_SECONDS}"
  done
  case "${screenshot_state}" in
    ok) echo "    window shows the title screen (OCR)"; ARTIFACTS+=("work/_gate/stage5/gate/window.png") ;;
    refused) echo "    window screenshot SKIPPED (screencapture refused; grant Screen Recording to enable)" ;;
    *)
      kill "${pid}" 2>/dev/null || true
      fail_gate "G5: App" "${gate_start}" "Window screenshots lacked '${SCREENSHOT_TEXT[0]}'. See work/_gate/stage5/gate/window.png."
      ;;
  esac
  while kill -0 "${pid}" 2>/dev/null && [[ $(( $(date +%s) - launch_time )) -lt "${WINDOWED_RUN_LIMIT_SECONDS}" ]]; do
    sleep 1
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true
    fail_gate "G5: App" "${gate_start}" "The app did not quit after --frames=${WINDOWED_FRAMES} within ${WINDOWED_RUN_LIMIT_SECONDS}s; it was stopped."
  fi
fi
pass_gate "G5: App" "${gate_start}"

# ── G6: earlier stages still pass ───────────────────────────────────
gate_start="$(date +%s)"
echo "[G6] Regression: Stage 2 (--skip-launch), Stage 3, Stage 4 gates"
for gate in "stage2_gate.sh --skip-launch" "stage3_gate.sh" "stage4_gate.sh"; do
  # shellcheck disable=SC2086
  if ! "${REPO_ROOT}/tests/"${gate} >>"${LOG_FILE}" 2>&1; then
    fail_gate "G6: Regression" "${gate_start}" "tests/${gate} failed; see ${LOG_FILE#"${REPO_ROOT}"/}."
  fi
  echo "    tests/${gate}: PASSED"
done
pass_gate "G6: Regression" "${gate_start}"

ARTIFACTS+=("${app#"${REPO_ROOT}"/}" "${build#"${REPO_ROOT}"/}/equivalence/equivalence.md" "${build#"${REPO_ROOT}"/}/fuzz/equivalence/equivalence.md")
print_artifacts
print_summary "PASSED"
