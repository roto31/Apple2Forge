#!/bin/bash
set -euo pipefail

# Stage 2 gate: is the T1 app real, ROM-free, and does it reach the game?
#   L0  bundle: layout, Info.plist tier, signature, no ROM bytes, notice,
#       launcher refuses to start without a ROM
#   L1  headless: the bundled emulator + bundled disk pass the 64K check and
#       reach the title screen; its hi-res text is read back with Vision OCR
#   L2  real launch: `open` the app, a window appears, it is still running
#       at 15 s, and the windowed run's own snapshot shows the title screen
#   L3  Virtual ][ reference boot via AppleScript (SKIPPED when unavailable)
# Exit codes: 0 all required levels passed, 1 a level failed, 2 config error.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DEFAULT_APP="${REPO_ROOT}/work/mecc-a170-number-munchers/t1/Number Munchers.app"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2plus.rom"
readonly TOOLS_SRC="${REPO_ROOT}/tests/tools"
readonly TOOLS_BIN="${REPO_ROOT}/build/test-tools"
readonly RESULT_DIR="${REPO_ROOT}/work/_gate/stage2"
# Number Munchers: $1E95 is the title screen's keyboard/joystick wait loop.
readonly TITLE_KEY_WAIT="1E95"
readonly HEADLESS_FRAMES=1500
readonly WINDOWED_FRAMES=1200
readonly STILL_RUNNING_AFTER_SECONDS=15
readonly WINDOW_WAIT_SECONDS=10
readonly WINDOWED_RUN_LIMIT_SECONDS=60
readonly RUN_TIMEOUT_SECONDS=60
readonly V2_APP="/Volumes/Virtual ][/Virtual ][.app"
readonly V2_ANSWER_SECONDS=15
readonly V2_BOOT_SECONDS=25
readonly EXPECTED_TEXT=("number munchers" "joystick")
# By 15 s the joystick question has timed out to the main menu; only the title
# is common to both screens.
readonly SCREENSHOT_TEXT=("number munchers")
# Without input the game cycles title → menu → demo board, and Virtual ][ may be
# on any of them when L3 dumps memory. Phrases joined by '+' must all appear.
# OCR often drops the "L" of "Level:" on the board, hence "evel".
readonly GAME_SCREENS=("number munchers" "evel+score:")
readonly SCREENSHOT_ATTEMPTS=3
readonly SCREENSHOT_RETRY_SECONDS=2
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/stage2_gate.log"
SUMMARY_TITLE="Stage 2 gate (T1 app)"
# shellcheck source=../tools/lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<'EOF'
Usage: tests/stage2_gate.sh [--app PATH] [--skip-launch]

  --app PATH      T1 app to test (default: work/mecc-a170-number-munchers/t1/Number Munchers.app)
  --skip-launch   Skip L2 (it opens a window for ~20 s) and L3.
EOF
}

app="${DEFAULT_APP}"
skip_launch=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --app) app="${2:?--app needs a path}"; shift 2 ;;
    --skip-launch) skip_launch=1; shift ;;
    *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ ! -d "${app}" ]]; then
  echo "ERROR: app not found: ${app}" >&2
  exit 2
fi
# AppleScript (L3) resolves relative paths against /, so the app path must be absolute.
app="$(cd "${app}" && pwd)"
readonly CONTENTS="${app}/Contents"
readonly BUNDLED_EMULATOR="${CONTENTS}/MacOS/a2emu"
readonly BUNDLED_DISK="${CONTENTS}/Resources/disk.dsk"

mkdir -p "${LOG_DIR}" "${RESULT_DIR}" "${TOOLS_BIN}"
echo "=== stage2_gate.sh $(date '+%Y-%m-%d %H:%M:%S %z') app=${app}" >> "${LOG_FILE}"

run_limited() {
  local seconds="$1"; shift
  perl -e 'alarm shift; exec { $ARGV[0] } @ARGV' "${seconds}" "$@"
}

# ocr_lowercase PNG LABEL → prints the recognised text in lower case and logs it.
ocr_lowercase() {
  local png="$1" label="$2" text
  text="$("${TOOLS_BIN}/ocr_text" "${png}" 2>>"${LOG_FILE}" | tr '[:upper:]' '[:lower:]')"
  echo "OCR ${label}: $(echo "${text}" | tr '\n' '|')" | tee -a "${LOG_FILE}" | sed 's/^/    /' >&2
  echo "${text}"
}

# text_has_all TEXT PHRASE... → 0 if every PHRASE occurs in TEXT.
text_has_all() {
  local text="$1" phrase
  shift
  for phrase in "$@"; do
    if [[ "${text}" != *"${phrase}"* ]]; then return 1; fi
  done
  return 0
}

# ocr_has_text PNG LABEL PHRASE... → 0 if every PHRASE is found (case-insensitive).
ocr_has_text() {
  local png="$1" label="$2" text
  shift 2
  text="$(ocr_lowercase "${png}" "${label}")"
  text_has_all "${text}" "$@"
}

# ocr_shows_game_screen PNG LABEL → 0 if the page matches any entry in GAME_SCREENS.
ocr_shows_game_screen() {
  local text screen
  local -a phrases
  text="$(ocr_lowercase "$1" "$2")"
  for screen in "${GAME_SCREENS[@]}"; do
    IFS='+' read -r -a phrases <<< "${screen}"
    if text_has_all "${text}" "${phrases[@]}"; then return 0; fi
  done
  return 1
}

# render_title SNAPSHOT PNG → renders the hi-res page named in SNAPSHOT.regs.
render_title() {
  local snapshot="$1" png="$2" page
  page="$(awk '$1 == "vidpage" { print $2 }' "${snapshot}.regs")"
  python3 -I "${TOOLS_SRC}/hgr_to_png.py" "${snapshot}" "${page:-1}" "${png}" 2
}

# ── Gate T: test tools ──────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate T] Test tools"
for tool in ocr_text window_list; do
  if [[ ! -x "${TOOLS_BIN}/${tool}" || "${TOOLS_SRC}/${tool}.swift" -nt "${TOOLS_BIN}/${tool}" ]]; then
    if ! swiftc -O -o "${TOOLS_BIN}/${tool}" "${TOOLS_SRC}/${tool}.swift" >>"${LOG_FILE}" 2>&1; then
      fail_gate "Gate T: Test tools" "${gate_start}" "swiftc failed for tests/tools/${tool}.swift; see log." 2
    fi
  fi
done
if [[ ! -r "${ROM_FILE}" ]]; then
  fail_gate "Gate T: Test tools" "${gate_start}" "Missing roms/apple2plus.rom (needed for the no-ROM scan). Run tools/05_fetch_rom.sh --install." 2
fi
pass_gate "Gate T: Test tools" "${gate_start}"

# ── L0: bundle ──────────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[L0] Bundle layout, tier, signature, no ROM, notice"
for needed in "${CONTENTS}/Info.plist" "${CONTENTS}/MacOS/launcher" "${BUNDLED_EMULATOR}" "${BUNDLED_DISK}" \
  "${CONTENTS}/Resources/NOTICE.txt" "${CONTENTS}/Resources/licenses/apple2tc-LICENSE.txt" \
  "${CONTENTS}/Resources/licenses/sokol-LICENSE.txt" "${CONTENTS}/Resources/licenses/nlohmann-json-LICENSE.txt"; do
  if [[ ! -e "${needed}" ]]; then
    fail_gate "L0: Bundle" "${gate_start}" "Missing ${needed#"${app}"/}. Rebuild with tools/20_wrap_t1.sh."
  fi
done
tier="$(plutil -extract A2NTier raw "${CONTENTS}/Info.plist" 2>/dev/null || true)"
if [[ "${tier}" != "T1" ]]; then
  fail_gate "L0: Bundle" "${gate_start}" "Info.plist A2NTier is '${tier}', expected T1."
fi
if ! codesign --verify --strict --deep "${app}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "L0: Bundle" "${gate_start}" "codesign --verify --strict failed. Rebuild with tools/20_wrap_t1.sh."
fi
if ! grep -q "DO NOT DISTRIBUTE" "${CONTENTS}/Resources/NOTICE.txt"; then
  fail_gate "L0: Bundle" "${gate_start}" "NOTICE.txt lacks the personal-use warning."
fi
if ! python3 -I - "${ROM_FILE}" "${app}" <<'PY' >>"${LOG_FILE}" 2>&1
import os, sys
rom = open(sys.argv[1], "rb").read()
windows = [rom[off:off + 256] for off in range(0, len(rom), 256)]
hits = [path for folder, _, files in os.walk(sys.argv[2]) for path in (os.path.join(folder, n) for n in files)
        if any(w in open(path, "rb").read() for w in windows)]
print("L0 ROM scan hits:", hits or "none")
sys.exit(1 if hits else 0)
PY
then
  fail_gate "L0: Bundle" "${gate_start}" "ROM bytes found inside the app (see log). Do not ship it."
fi
empty_home="$(mktemp -d)"
no_rom_status=0
HOME="${empty_home}" A2N_SUPPRESS_ALERT=1 run_limited 10 "${CONTENTS}/MacOS/launcher" >>"${LOG_FILE}" 2>&1 || no_rom_status=$?
no_rom_logged=0
if grep -q "ROM not found" "${empty_home}/Library/Logs/Apple2Forge/"*.log 2>/dev/null; then no_rom_logged=1; fi
rm -rf "${empty_home}"
if [[ "${no_rom_status}" -ne 1 || "${no_rom_logged}" -ne 1 ]]; then
  fail_gate "L0: Bundle" "${gate_start}" "With no ROM installed the launcher exited ${no_rom_status} (expected 1 and a 'ROM not found' log line)."
fi
echo "    tier T1, signature valid, no ROM bytes, notice present, refuses to start without a ROM"
pass_gate "L0: Bundle" "${gate_start}"

# ── L1: headless boot to the title screen ───────────────────────────
gate_start="$(date +%s)"
echo "[L1] Headless: 64K check, \$3000, title screen text"
if ! "${REPO_ROOT}/tests/stage2_language_card.sh" --binary "${BUNDLED_EMULATOR}" --disk "${BUNDLED_DISK}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "L1: Headless title" "${gate_start}" "tests/stage2_language_card.sh failed against the bundled emulator and disk; run it with --binary/--disk to see which check."
fi
l1_snapshot="${RESULT_DIR}/l1_title.snap"
rm -f "${l1_snapshot}" "${l1_snapshot}.regs"
run_limited "${RUN_TIMEOUT_SECONDS}" "${BUNDLED_EMULATOR}" --headless --no-sound --frames="${HEADLESS_FRAMES}" \
  --rom="${ROM_FILE}" --disk1="${BUNDLED_DISK}" --snapshot-at="${TITLE_KEY_WAIT}" --snapshot-out="${l1_snapshot}" >>"${LOG_FILE}" 2>&1 || true
if [[ ! -f "${l1_snapshot}" ]]; then
  fail_gate "L1: Headless title" "${gate_start}" "Title key wait \$${TITLE_KEY_WAIT} not reached in ${HEADLESS_FRAMES} frames."
fi
render_title "${l1_snapshot}" "${RESULT_DIR}/l1_title.png"
ARTIFACTS+=("work/_gate/stage2/l1_title.png")
if ! ocr_has_text "${RESULT_DIR}/l1_title.png" "L1" "${EXPECTED_TEXT[@]}"; then
  fail_gate "L1: Headless title" "${gate_start}" "Title screen text did not include: ${EXPECTED_TEXT[*]}. Open work/_gate/stage2/l1_title.png to see what was on screen."
fi
pass_gate "L1: Headless title" "${gate_start}"

if [[ "${skip_launch}" -eq 1 ]]; then
  skip_gate "L2: Real launch" "--skip-launch"
  skip_gate "L3: Virtual ][ reference" "--skip-launch"
  print_artifacts
  print_summary "PASSED (L2/L3 skipped)"
  exit 0
fi

# ── L2: real launch through LaunchServices ──────────────────────────
gate_start="$(date +%s)"
echo "[L2] Real launch: window, still running at ${STILL_RUNNING_AFTER_SECONDS}s, title screen"
emulator_pattern="${app#"${REPO_ROOT}"/work/}/Contents/MacOS/a2emu"
if pgrep -f "${emulator_pattern}" >/dev/null; then
  fail_gate "L2: Real launch" "${gate_start}" "The app is already running; quit it and re-run the gate." 2
fi
l2_snapshot="${RESULT_DIR}/l2_title.snap"
rm -f "${l2_snapshot}" "${l2_snapshot}.regs"
launch_time="$(date +%s)"
open -n "${app}" --args --no-sound --frames="${WINDOWED_FRAMES}" \
  --snapshot-at="${TITLE_KEY_WAIT}" --snapshot-out="${l2_snapshot}"
pid=""
window_info=""
for _ in $(seq "${WINDOW_WAIT_SECONDS}"); do
  sleep 1
  pid="$(pgrep -f "${emulator_pattern}" | head -n 1 || true)"
  if [[ -n "${pid}" ]]; then
    window_info="$("${TOOLS_BIN}/window_list" "${pid}" 2>/dev/null || true)"
    if [[ -n "${window_info}" ]]; then break; fi
  fi
done
if [[ -z "${pid}" || -z "${window_info}" ]]; then
  fail_gate "L2: Real launch" "${gate_start}" "No emulator window within ${WINDOW_WAIT_SECONDS}s (pid='${pid}'). Check ~/Library/Logs/Apple2Forge/ and Console.app."
fi
echo "    pid ${pid}, window ${window_info}"
sleep $(( STILL_RUNNING_AFTER_SECONDS - ($(date +%s) - launch_time) > 0 ? STILL_RUNNING_AFTER_SECONDS - ($(date +%s) - launch_time) : 0 ))
if ! kill -0 "${pid}" 2>/dev/null; then
  fail_gate "L2: Real launch" "${gate_start}" "The app quit before ${STILL_RUNNING_AFTER_SECONDS}s. See ~/Library/Logs/Apple2Forge/."
fi
echo "    still running at ${STILL_RUNNING_AFTER_SECONDS}s"
window_id="${window_info%% *}"
rm -f "${RESULT_DIR}/l2_window.png"
# The game redraws the whole screen when the joystick question times out to
# the menu (around 15 s); a capture mid-redraw is blank, so retry a few times.
screenshot_state="refused"
for _ in $(seq "${SCREENSHOT_ATTEMPTS}"); do
  if ! screencapture -x -o -l "${window_id}" "${RESULT_DIR}/l2_window.png" >>"${LOG_FILE}" 2>&1 \
    || [[ ! -s "${RESULT_DIR}/l2_window.png" ]]; then
    break
  fi
  screenshot_state="no-text"
  if ocr_has_text "${RESULT_DIR}/l2_window.png" "L2 screenshot" "${SCREENSHOT_TEXT[@]}"; then
    screenshot_state="ok"
    break
  fi
  sleep "${SCREENSHOT_RETRY_SECONDS}"
done
case "${screenshot_state}" in
  ok) ARTIFACTS+=("work/_gate/stage2/l2_window.png") ;;
  refused) echo "    window screenshot SKIPPED (screencapture refused; grant Screen Recording to Cursor to enable)" ;;
  *)
    kill "${pid}" 2>/dev/null || true
    fail_gate "L2: Real launch" "${gate_start}" "${SCREENSHOT_ATTEMPTS} window screenshots lacked: ${SCREENSHOT_TEXT[*]}. See work/_gate/stage2/l2_window.png."
    ;;
esac
while kill -0 "${pid}" 2>/dev/null && [[ $(( $(date +%s) - launch_time )) -lt "${WINDOWED_RUN_LIMIT_SECONDS}" ]]; do
  sleep 1
done
if kill -0 "${pid}" 2>/dev/null; then
  kill "${pid}" 2>/dev/null || true
  fail_gate "L2: Real launch" "${gate_start}" "The app did not quit after --frames=${WINDOWED_FRAMES} within ${WINDOWED_RUN_LIMIT_SECONDS}s; it was stopped."
fi
if [[ ! -f "${l2_snapshot}" ]]; then
  fail_gate "L2: Real launch" "${gate_start}" "The windowed run never reached the title key wait \$${TITLE_KEY_WAIT}."
fi
render_title "${l2_snapshot}" "${RESULT_DIR}/l2_title.png"
ARTIFACTS+=("work/_gate/stage2/l2_title.png")
if ! ocr_has_text "${RESULT_DIR}/l2_title.png" "L2" "${EXPECTED_TEXT[@]}"; then
  fail_gate "L2: Real launch" "${gate_start}" "Windowed run's title screen text did not include: ${EXPECTED_TEXT[*]}. See work/_gate/stage2/l2_title.png."
fi
pass_gate "L2: Real launch" "${gate_start}"

# ── L3: Virtual ][ reference (optional) ─────────────────────────────
gate_start="$(date +%s)"
echo "[L3] Virtual ][ reference boot"
if [[ ! -d "${V2_APP}" ]]; then
  skip_gate "L3: Virtual ][ reference" "Virtual ][ volume not mounted"
elif ! pgrep -f 'Virtual \]\[\.app/Contents/MacOS/' >/dev/null; then
  skip_gate "L3: Virtual ][ reference" "Virtual ][ is not running; open it, then re-run"
elif ! run_limited "${V2_ANSWER_SECONDS}" osascript -e 'tell application "Virtual ][" to count of machines' >>"${LOG_FILE}" 2>&1; then
  skip_gate "L3: Virtual ][ reference" "Virtual ][ did not answer AppleScript in ${V2_ANSWER_SECONDS}s (a dialog or the Automation permission prompt may be waiting)"
else
  v2_prefix="${RESULT_DIR}/v2"
  rm -f "${v2_prefix}.hgr1" "${v2_prefix}.hgr2"
  v2_status=0
  v2_output="$(run_limited $(( V2_BOOT_SECONDS + 90 )) osascript "${TOOLS_SRC}/v2_boot_check.applescript" \
    "${BUNDLED_DISK}" "${v2_prefix}" "${V2_BOOT_SECONDS}" 2>&1)" || v2_status=$?
  echo "${v2_output}" >> "${LOG_FILE}"
  if [[ "${v2_status}" -ne 0 ]]; then
    skip_gate "L3: Virtual ][ reference" "AppleScript boot check exited ${v2_status}: $(echo "${v2_output}" | tail -n 1 | sed -E 's/.*execution error: //')"
  elif [[ "${v2_output}" == *"no-rom"* ]]; then
    skip_gate "L3: Virtual ][ reference" "Virtual ][ has no ROM for its front machine type (it shows NO SUITABLE ROM FILE)"
  else
    v2_matched=0
    for page in 1 2; do
      if [[ -f "${v2_prefix}.hgr${page}" ]]; then
        python3 -I "${TOOLS_SRC}/hgr_to_png.py" "${v2_prefix}.hgr${page}" "${page}" "${RESULT_DIR}/v2_hgr${page}.png" 2
        if ocr_shows_game_screen "${RESULT_DIR}/v2_hgr${page}.png" "L3 page ${page}"; then v2_matched=1; fi
      fi
    done
    if [[ "${v2_matched}" -ne 1 ]]; then
      fail_gate "L3: Virtual ][ reference" "${gate_start}" "Virtual ][ booted the same disk but neither hi-res page shows a Number Munchers screen (title, menu or board). Compare work/_gate/stage2/v2_hgr*.png with l1_title.png."
    fi
    pass_gate "L3: Virtual ][ reference" "${gate_start}"
  fi
fi

print_artifacts
print_summary "PASSED"
