#!/bin/bash
set -euo pipefail

# Stage 6 gate: Apple2Forge.app as the drag-and-drop build tool.
#   B1  The app builds (version, project path and disk document types in its
#       Info.plist), carries no ROM bytes, and passes codesign --verify.
#   B2  The Swift unit tests pass (report tiers, T2 rules, setup parsing).
#   B3  --build on the Number Munchers disk: Analyze PASS, Wrap (T1) PASS, a
#       signed T1 app (A2NTier=T1) and report.json in the builds folder.
#   B4  UI: the disk opened on the app (as a Finder drop on its icon does) runs
#       Analyze and Wrap (T1) automatically; the window shows both PASS (OCR);
#       a .txt dropped with it is refused with a message, not a crash.
#   B5  An unsupported .nib is analyzed and Wrap (T1) is SKIPPED as unsupported.
#   B6  Two disks dropped together are both built, one after the other.
#   B7  Record coverage (headless, scripted keys) reports coverage, and its
#       replay runs exactly the recorded code.
#   B8  First run: the setup check runs Stage 0 and records a pass.
#   B9  --build --t2: the full pipeline builds the T2-hybrid app (skip: --skip-t2).
#   B10 Regressions: the Stage 6a library gate (--skip-download).
#   B11 SIGTERM during Coverage stops the stage's whole process tree, and the
#       report says Coverage was cancelled (runs before B10).
# Builds go to a temporary folder and settings to a throwaway defaults domain.
# Exit codes: 0 PASS, 1 gate failed, 2 config error.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly APP="${REPO_ROOT}/build/Apple2Forge.app"
readonly APP_BINARY="${APP}/Contents/MacOS/Apple2Forge"
readonly DISK="${REPO_ROOT}/MECC-A170 Number Munchers v1.3 (4am crack)/MECC-A170 Number Munchers v1.3 (4am crack).dsk"
readonly SECOND_DISK="${REPO_ROOT}/MECC-A170 Number Munchers.dsk"
readonly SLUG="mecc-a170-number-munchers-v1-3-4am-crack"
readonly SECOND_SLUG="mecc-a170-number-munchers"
readonly WALK_KEYS="${REPO_ROOT}/tests/fixtures/stage3_walk.keys"
readonly WINDOW_LIST="${REPO_ROOT}/tests/tools/window_list.swift"
readonly TOOLS_SRC="${REPO_ROOT}/tests/tools"
readonly TOOLS_BIN="${REPO_ROOT}/build/test-tools"
readonly OUT_DIR="${REPO_ROOT}/work/_gate/stage6"
readonly SETUP_LOG="${HOME}/Library/Logs/Apple2Forge/setup-check.log"
readonly UI_BUILD_TIMEOUT_SECONDS=120
readonly SETUP_TIMEOUT_SECONDS=600
readonly QUIT_AFTER_BUILD_SECONDS=6
readonly CANCEL_WAIT_SECONDS=60
readonly CANCEL_EXIT_SECONDS=15
readonly DEFAULTS_SUITE="local.apple2native.Apple2Forge.buildgate.$$"
LOG_FILE="${OUT_DIR}/build_gate.log"
SUMMARY_TITLE="Stage 6 Apple2Forge build-tool gate"
# shellcheck source=../tools/lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  echo "Usage: tests/stage6_build_gate.sh [--skip-t2] [--no-ui] [--help]"
  echo "  --skip-t2  Skip B9 (the full T2 build takes about 9 minutes)."
  echo "  --no-ui    Skip B4, B6, B8 and B10, which open windows (and B10 stops running"
  echo "             library titles); use while someone else is using Apple2Forge."
}
SKIP_T2=0
SKIP_UI=0
for arg in "$@"; do
  case "${arg}" in
    --help|-h) usage; exit 0 ;;
    --skip-t2) SKIP_T2=1 ;;
    --no-ui) SKIP_UI=1 ;;
    *) echo "ERROR: unknown option ${arg}" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "${OUT_DIR}" "${TOOLS_BIN}"
: > "${LOG_FILE}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/a2forge-build-gate.XXXXXX")"
APP_PID=""
cleanup() {
  if [[ -n "${APP_PID}" ]]; then kill "${APP_PID}" 2>/dev/null || true; fi
  defaults delete "${DEFAULTS_SUITE}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

app_cli() {
  "${APP_BINARY}" --defaults-suite="${DEFAULTS_SUITE}" --skip-first-run --project="${REPO_ROOT}" "$@"
}

# report_check REPORT_JSON STAGE=STATUS... → 0 if every stage has that status
# (PASS, FAIL, SKIPPED); SKIPPED:TEXT also needs TEXT in the reason.
report_check() {
  python3 -I - "$@" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
labels = {"passed": "PASS", "failed": "FAIL", "skipped": "SKIPPED", "pending": "WAITING", "running": "RUNNING"}
problems = []
for want in sys.argv[2:]:
    stage, expected = want.split("=", 1)
    status = next(s["status"] for s in record["stages"] if s["stage"] == stage)
    kind = next(iter(status))
    detail = json.dumps(status[kind])
    label = labels[kind]
    expected_label, _, text = expected.partition(":")
    if label != expected_label or (text and text not in detail):
        problems.append(f"{stage}: {label} {detail}, wanted {expected}")
print("\n".join(problems) or "stages OK")
sys.exit(1 if problems else 0)
PY
}

# wait_for FILE SECONDS → 0 once FILE exists.
wait_for() {
  local waited=0
  while [[ ! -s "$1" ]]; do
    if [[ "${waited}" -ge "$2" ]]; then return 1; fi
    sleep 1
    waited=$(( waited + 1 ))
  done
}

# wait_exit PID SECONDS → 0 once PID has exited.
wait_exit() {
  local waited=0
  while kill -0 "$1" 2>/dev/null; do
    if [[ "${waited}" -ge "$2" ]]; then return 1; fi
    sleep 1
    waited=$(( waited + 1 ))
  done
}

# skip_ui_gate ID → records a gate skipped by --no-ui.
skip_ui_gate() {
  echo "[Gate $1] SKIPPED (--no-ui)"
  SKIPPED_GATES="${SKIPPED_GATES:-} $1"
}

# ocr_window PID PNG → prints the window's text in lower case.
ocr_window() {
  local windows
  windows="$(swift "${WINDOW_LIST}" "$1" 2>> "${LOG_FILE}" || true)"
  if [[ -z "${windows}" ]]; then return 1; fi
  screencapture -x -o -l "${windows%% *}" "$2" 2>> "${LOG_FILE}" || return 1
  "${TOOLS_BIN}/ocr_text" "$2" 2>> "${LOG_FILE}" | tr '[:upper:]' '[:lower:]'
}

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs and test tools"
for needed in "${DISK}" "${SECOND_DISK}" "${WALK_KEYS}" "${REPO_ROOT}/roms/apple2plus.rom" \
              "${REPO_ROOT}/build/a2emu-norom/a2emu"; do
  if [[ ! -r "${needed}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${needed#"${REPO_ROOT}"/}." 2
  fi
done
if [[ ! -x "${TOOLS_BIN}/ocr_text" || "${TOOLS_SRC}/ocr_text.swift" -nt "${TOOLS_BIN}/ocr_text" ]]; then
  if ! swiftc -O -o "${TOOLS_BIN}/ocr_text" "${TOOLS_SRC}/ocr_text.swift" >> "${LOG_FILE}" 2>&1; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "swiftc failed for tests/tools/ocr_text.swift." 2
  fi
fi
pass_gate "Gate 0: Inputs" "${gate_start}"

# ── Gate B1: build ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate B1] Build, Info.plist, ROM check and signature"
if ! bash "${REPO_ROOT}/tools/60_build_app.sh" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate B1: Build" "${gate_start}" "tools/60_build_app.sh failed; see ${LOG_FILE}."
fi
plist="${APP}/Contents/Info.plist"
if [[ "$(plutil -extract A2FProjectRoot raw "${plist}" 2>/dev/null)" != "${REPO_ROOT}" ]] \
   || [[ "$(plutil -extract CFBundleShortVersionString raw "${plist}")" != "0.2.0" ]] \
   || ! plutil -p "${plist}" | grep -q '"nib"'; then
  fail_gate "Gate B1: Build" "${gate_start}" "Info.plist lacks the project path, version 0.2.0 or the disk document types."
fi
if ! codesign --verify --strict --deep "${APP}" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate B1: Build" "${gate_start}" "codesign --verify failed."
fi
pass_gate "Gate B1: Build" "${gate_start}"

# ── Gate B2: unit tests ─────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate B2] Swift unit tests"
if ! (cd "${REPO_ROOT}/app/Apple2Forge" && swift test) >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate B2: Unit tests" "${gate_start}" "swift test failed; see ${LOG_FILE}."
fi
pass_gate "Gate B2: Unit tests" "${gate_start}"

# ── Gate B3: command-line build ─────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate B3] --build: Analyze and Wrap (T1) pass, T1 app and report"
builds="${WORK}/cli"
if ! app_cli --builds-dir="${builds}" --build="${DISK}" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate B3: CLI build" "${gate_start}" "Apple2Forge --build failed; see ${LOG_FILE}."
fi
report="${builds}/${SLUG}/report.json"
t1_app="$(find "${builds}/${SLUG}" -maxdepth 1 -name '*.app' | head -1)"
if [[ ! -s "${report}" ]] || ! report_check "${report}" "Analyze=PASS" "Wrap (T1)=PASS" "Package=PASS" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate B3: CLI build" "${gate_start}" "report.json is missing or a stage did not pass; see ${LOG_FILE}."
fi
if [[ -z "${t1_app}" ]] || ! codesign --verify --strict --deep "${t1_app}" >> "${LOG_FILE}" 2>&1 \
   || [[ "$(plutil -extract A2NTier raw "${t1_app}/Contents/Info.plist")" != "T1" ]]; then
  fail_gate "Gate B3: CLI build" "${gate_start}" "No signed T1 app in ${builds}/${SLUG}."
fi
echo "    $(basename "${t1_app}") built and signed"
pass_gate "Gate B3: CLI build" "${gate_start}"

# ── Gate B4: open on the app icon, window shows PASS ────────────────
if [[ "${SKIP_UI}" -eq 1 ]]; then
  skip_ui_gate "B4"
else
  gate_start="$(date +%s)"
  echo "[Gate B4] Disk opened on the app: Analyze and Wrap (T1) PASS in the window"
  builds="${WORK}/ui"
  echo "notes" > "${WORK}/notes.txt"
  defaults write "${DEFAULTS_SUITE}" setupCheckPassed -bool true
  open -n -a "${APP}" "${DISK}" --args --defaults-suite="${DEFAULTS_SUITE}" --skip-first-run --project="${REPO_ROOT}" \
    --builds-dir="${builds}" --drop="${WORK}/notes.txt" --quit-after-build="${QUIT_AFTER_BUILD_SECONDS}"
  sleep 2
  APP_PID="$(pgrep -n -f "$(printf '%s' "${APP_BINARY}" | sed 's/[][\.*^$()+?{}|]/\\&/g')" || true)"
  report="${builds}/${SLUG}/report.json"
  if [[ -z "${APP_PID}" ]] || ! wait_for "${report}" "${UI_BUILD_TIMEOUT_SECONDS}"; then
    fail_gate "Gate B4: UI build" "${gate_start}" "The app did not finish a build within ${UI_BUILD_TIMEOUT_SECONDS}s; see ${builds}/${SLUG}/logs."
  fi
  sleep 1
  text="$(ocr_window "${APP_PID}" "${OUT_DIR}/b4_window.png" || true)"
  echo "B4 OCR: $(echo "${text}" | tr '\n' '|')" >> "${LOG_FILE}"
  if ! wait_exit "${APP_PID}" $(( QUIT_AFTER_BUILD_SECONDS + 10 )); then
    fail_gate "Gate B4: UI build" "${gate_start}" "The app did not quit after the build (hung or crashed dialog)."
  fi
  APP_PID=""
  if ! report_check "${report}" "Analyze=PASS" "Wrap (T1)=PASS" >> "${LOG_FILE}" 2>&1; then
    fail_gate "Gate B4: UI build" "${gate_start}" "Analyze or Wrap (T1) did not pass; see ${LOG_FILE}."
  fi
  # Analyze, Wrap (T1) and Package each show PASS.
  pass_words="$(grep -oE '\bpass\b' <<< "${text}" | wc -l | tr -d ' ')"
  if [[ "${text}" != *"analyze"* || "${text}" != *"wrap (t1)"* || "${pass_words}" -lt 3 \
        || "${text}" != *"not a disk image"* ]]; then
    fail_gate "Gate B4: UI build" "${gate_start}" "The window did not show Analyze and Wrap (T1) PASS and the .txt refusal; see ${OUT_DIR}/b4_window.png."
  fi
  ARTIFACTS+=("work/_gate/stage6/b4_window.png")
  echo "    window shows Analyze PASS, Wrap (T1) PASS and the .txt refusal"
  pass_gate "Gate B4: UI build" "${gate_start}"
fi

# ── Gate B5: unsupported format ─────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate B5] An unsupported .nib is reported, not wrapped"
head -c 232960 /dev/zero > "${WORK}/blank.nib"
if ! app_cli --builds-dir="${WORK}/nib" --build="${WORK}/blank.nib" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate B5: Unsupported" "${gate_start}" "Apple2Forge --build failed on the .nib; see ${LOG_FILE}."
fi
if ! report_check "${WORK}/nib/blank/report.json" "Analyze=PASS" "Wrap (T1)=SKIPPED:Unsupported" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate B5: Unsupported" "${gate_start}" "The .nib was not reported as unsupported; see ${LOG_FILE}."
fi
pass_gate "Gate B5: Unsupported" "${gate_start}"

# ── Gate B6: a queue of two disks ───────────────────────────────────
if [[ "${SKIP_UI}" -eq 1 ]]; then
  skip_ui_gate "B6"
else
  gate_start="$(date +%s)"
  echo "[Gate B6] Two dropped disks are both built"
  builds="${WORK}/queue"
  "${APP_BINARY}" --defaults-suite="${DEFAULTS_SUITE}" --project="${REPO_ROOT}" --builds-dir="${builds}" \
    --drop="${SECOND_DISK}" --drop="${DISK}" --quit-after-build=1 >> "${LOG_FILE}" 2>&1 &
  APP_PID=$!
  if ! wait_exit "${APP_PID}" $(( UI_BUILD_TIMEOUT_SECONDS * 2 )); then
    fail_gate "Gate B6: Queue" "${gate_start}" "The queue did not finish."
  fi
  APP_PID=""
  for slug in "${SECOND_SLUG}" "${SLUG}"; do
    if [[ ! -s "${builds}/${slug}/report.json" ]] || ! report_check "${builds}/${slug}/report.json" "Analyze=PASS" >> "${LOG_FILE}" 2>&1; then
      fail_gate "Gate B6: Queue" "${gate_start}" "${slug} was not built; see ${LOG_FILE}."
    fi
    echo "    ${slug}: tier $(plutil -extract report.tier raw -o - "${builds}/${slug}/report.json" 2>/dev/null || echo '?')"
  done
  pass_gate "Gate B6: Queue" "${gate_start}"
fi

# ── Gate B7: record and replay ──────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate B7] Record coverage, then replay it exactly"
recording="${WORK}/recording"
if ! bash "${REPO_ROOT}/tools/45_record.sh" "${DISK}" --out "${recording}" --keys "${WALK_KEYS}" \
     --frames 1800 --headless >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate B7: Record" "${gate_start}" "tools/45_record.sh failed; see ${LOG_FILE}."
fi
recorded_keys="$(wc -l < "${recording}/session.keys" | tr -d ' ')"
if [[ "${recorded_keys}" -ne "$(grep -cE '^[0-9]+ [0-9]+' "${WALK_KEYS}")" || ! -s "${recording}/record.md" ]]; then
  fail_gate "Gate B7: Record" "${gate_start}" "Recorded ${recorded_keys} keys or no report; see ${recording}."
fi
replay_output="$(bash "${REPO_ROOT}/tools/45_record.sh" "${DISK}" --out "${recording}" --replay --frames 1800 --headless 2>&1)" || true
echo "${replay_output}" >> "${LOG_FILE}"
if [[ "${replay_output}" != *"replay ran exactly the recorded code"* ]]; then
  fail_gate "Gate B7: Record" "${gate_start}" "The replay did not run exactly the recorded code."
fi
echo "    ${recorded_keys} keys recorded; replay exact"
pass_gate "Gate B7: Record" "${gate_start}"

# ── Gate B8: first-run setup check ──────────────────────────────────
if [[ "${SKIP_UI}" -eq 1 ]]; then
  skip_ui_gate "B8"
else
  gate_start="$(date +%s)"
  echo "[Gate B8] First run runs the Stage 0 setup check"
  defaults delete "${DEFAULTS_SUITE}" >/dev/null 2>&1 || true
  rm -f "${SETUP_LOG}"
  "${APP_BINARY}" --defaults-suite="${DEFAULTS_SUITE}" --skip-first-run --project="${REPO_ROOT}" >> "${LOG_FILE}" 2>&1 &
  APP_PID=$!
  waited=0
  while ! grep -q '^Overall:' "${SETUP_LOG}" 2>/dev/null; do
    if [[ "${waited}" -ge "${SETUP_TIMEOUT_SECONDS}" ]]; then break; fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  sleep 2
  setup_passed="$(defaults read "${DEFAULTS_SUITE}" setupCheckPassed 2>/dev/null || echo missing)"
  kill "${APP_PID}" 2>/dev/null || true
  wait "${APP_PID}" 2>/dev/null || true
  APP_PID=""
  if ! grep -q '^Overall: PASSED' "${SETUP_LOG}" 2>/dev/null || [[ "${setup_passed}" != "1" ]]; then
    fail_gate "Gate B8: Setup check" "${gate_start}" "The first-run check did not pass (recorded: ${setup_passed}); see ${SETUP_LOG}."
  fi
  echo "    $(grep -c 'PASSED' "${SETUP_LOG}") gate lines passed; recorded as passed"
  pass_gate "Gate B8: Setup check" "${gate_start}"
fi

# ── Gate B9: full T2 build ──────────────────────────────────────────
gate_start="$(date +%s)"
if [[ "${SKIP_T2}" -eq 1 ]]; then
  echo "[Gate B9] SKIPPED (--skip-t2)"
  SKIPPED_GATES="${SKIPPED_GATES:-} B9"
else
  echo "[Gate B9] --build --t2: the full pipeline builds the T2-hybrid app (about 9 minutes)"
  builds="${WORK}/t2"
  if ! app_cli --builds-dir="${builds}" --t2 --build="${DISK}" >> "${LOG_FILE}" 2>&1; then
    fail_gate "Gate B9: T2 build" "${gate_start}" "Apple2Forge --build --t2 failed; see ${LOG_FILE} and ${builds}/${SLUG}/logs."
  fi
  t2_app="$(find "${builds}/${SLUG}" -maxdepth 1 -name '*(T2-hybrid).app' | head -1)"
  if [[ -z "${t2_app}" ]] || [[ "$(plutil -extract A2NTier raw "${t2_app}/Contents/Info.plist")" != "T2-hybrid" ]] \
     || ! report_check "${builds}/${SLUG}/report.json" "Capture=PASS" "Coverage=PASS" "Recompile (T2)=PASS" >> "${LOG_FILE}" 2>&1 \
     || [[ ! -s "${builds}/${SLUG}/equivalence.md" ]]; then
    fail_gate "Gate B9: T2 build" "${gate_start}" "No T2-hybrid app or equivalence report in ${builds}/${SLUG}."
  fi
  echo "    $(basename "${t2_app}") built; tier $(plutil -extract report.tier raw -o - "${builds}/${SLUG}/report.json")"
  pass_gate "Gate B9: T2 build" "${gate_start}"
fi

# ── Gate B11: cancel stops the whole stage ──────────────────────────
gate_start="$(date +%s)"
echo "[Gate B11] SIGTERM during Coverage stops every child and reports the cancel"
builds="${WORK}/cancel"
# Not app_cli: $! must be the app itself, not a subshell running the function.
"${APP_BINARY}" --defaults-suite="${DEFAULTS_SUITE}" --skip-first-run --project="${REPO_ROOT}" --builds-dir="${builds}" \
  --t2 --build="${DISK}" >> "${LOG_FILE}" 2>&1 &
APP_PID=$!
waited=0
while ! pgrep -f "tools/40_coverage.sh" >/dev/null; do
  if [[ "${waited}" -ge "${CANCEL_WAIT_SECONDS}" ]]; then break; fi
  sleep 1
  waited=$(( waited + 1 ))
done
sleep 5
kill -TERM "${APP_PID}" 2>/dev/null || true
cancel_exited=1
if ! wait_exit "${APP_PID}" "${CANCEL_EXIT_SECONDS}"; then cancel_exited=0; fi
APP_PID=""
sleep 2
# pgrep exits 1 when nothing matches, which is the passing case.
leftovers="$( (pgrep -f 'tools/40_coverage.sh|tools/lib/coverage_session.py|tools/lib/board_solver.py' || true) | wc -l | tr -d ' ')"
if [[ "${cancel_exited}" -ne 1 || "${leftovers}" -ne 0 ]] \
   || ! report_check "${builds}/${SLUG}/report.json" "Coverage=FAIL:cancelled" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate B11: Cancel" "${gate_start}" "Exited: ${cancel_exited}; ${leftovers} coverage processes left; see ${LOG_FILE}."
fi
echo "    exited, 0 coverage processes left, Coverage reported as cancelled"
pass_gate "Gate B11: Cancel" "${gate_start}"

# ── Gate B10: library regressions ───────────────────────────────────
if [[ "${SKIP_UI}" -eq 1 ]]; then
  skip_ui_gate "B10"
else
  gate_start="$(date +%s)"
  echo "[Gate B10] Stage 6a library gate"
  if ! bash "${REPO_ROOT}/tests/stage6_library_gate.sh" --skip-download >> "${LOG_FILE}" 2>&1; then
    fail_gate "Gate B10: Library gate" "${gate_start}" "tests/stage6_library_gate.sh failed; see ${LOG_FILE}."
  fi
  pass_gate "Gate B10: Library gate" "${gate_start}"
fi

if [[ -n "${SKIPPED_GATES:-}" ]]; then
  print_summary "PASSED (skipped:${SKIPPED_GATES})"
else
  print_summary "PASSED"
fi
