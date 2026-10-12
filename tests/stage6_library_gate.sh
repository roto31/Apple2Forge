#!/bin/bash
set -euo pipefail

# Stage 6a gate: Apple2Forge.app and its educational library menus.
#   A1  The app builds, carries no ROM bytes, and passes codesign --verify.
#   A2  The Library menu (--dump-menu) lists exactly the visible titles of
#       library.json under their subjects, in subject order.
#   A3  Starting a one-disk title (as the Library menu does) opens an a2emu
#       window titled after it, with the disk mounted in drive 1.
#   A4  A two-sided title starts with side A in drive 1 and side B in drive 2.
#   A5  Inserting a side into drive 1 (as the Disk menu does) reaches a2emu
#       over its control pipe and drive 1 then holds that side.
#   A6  --download-to with --limit=3 fills an empty folder and builds a catalog.
#   A7  A library folder inside an .app is refused.
#   A8  A chosen library folder is still remembered by the next app launch.
# Needs the downloaded library, installed ROMs, and network access for A6.
# Settings go to a throwaway defaults domain; the user's choice is untouched.
# Exit codes: 0 PASS, 1 gate failed, 2 config error.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly APP="${REPO_ROOT}/build/Apple2Forge.app"
readonly APP_BINARY="${APP}/Contents/MacOS/Apple2Forge"
readonly LIBRARY="${HOME}/Library/Application Support/Apple2Forge/library"
readonly EMULATOR_LOG="${HOME}/Library/Logs/Apple2Forge/emulator.log"
readonly LAUNCH_LINKS="${HOME}/Library/Caches/Apple2Forge/launch"
readonly WINDOW_LIST="${REPO_ROOT}/tests/tools/window_list.swift"
readonly OUT_DIR="${REPO_ROOT}/work/_gate/stage6"
readonly START_WAIT_SECONDS=8
readonly SWAP_DELAY_SECONDS=4
readonly DOWNLOAD_LIMIT=3
readonly DEFAULTS_SUITE="local.apple2native.Apple2Forge.gate.$$"
LOG_FILE="${OUT_DIR}/library_gate.log"
SUMMARY_TITLE="Stage 6a Apple2Forge library gate"
# shellcheck source=../tools/lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  echo "Usage: tests/stage6_library_gate.sh [--skip-download] [--help]"
  echo "  --skip-download  Skip A6 (no network)."
}
SKIP_DOWNLOAD=0
for arg in "$@"; do
  case "${arg}" in
    --help|-h) usage; exit 0 ;;
    --skip-download) SKIP_DOWNLOAD=1 ;;
    *) echo "ERROR: unknown option ${arg}" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "${OUT_DIR}"
: > "${LOG_FILE}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/a2forge-gate.XXXXXX")"
APP_PID=""
cleanup() {
  if [[ -n "${APP_PID}" ]]; then kill "${APP_PID}" 2>/dev/null || true; fi
  pkill -f "${LAUNCH_LINKS}/" 2>/dev/null || true
  defaults delete "${DEFAULTS_SUITE}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

app_cli() {
  "${APP_BINARY}" --defaults-suite="${DEFAULTS_SUITE}" "$@"
}

# Picks gate titles from library.json: KIND is "one-disk" or "two-sided".
# Prints id, window title, drive-1 path and drive-2 path (or "-") on separate lines.
pick_title() {
  python3 -I - "${LIBRARY}/library.json" "$1" <<'PY'
import json, sys
titles = json.load(open(sys.argv[1]))["titles"]
kind = sys.argv[2]
def ok(t):
    if t["hidden"] or t["requirement"] != "IIplus64K" or t["requirementSource"] != "sweep":
        return False
    sides = t["disks"][0]["sides"]
    if kind == "one-disk":
        return t["boot"]["drive2"] is None and len(t["disks"]) == 1 and len(sides) == 1
    return len(sides) == 2 and t["boot"]["drive2"] == sides[1]["path"]
t = sorted((t for t in titles if ok(t)), key=lambda t: t["id"])[0]
name = "".join("-" if c in "/:" else c for c in t["title"]).strip()
print(t["id"]); print(name); print(t["boot"]["drive1"]); print(t["boot"]["drive2"] or "-")
PY
}

# Starts the app UI with test hooks; leaves APP_PID set.
start_app() {
  pkill -f "${LAUNCH_LINKS}/" 2>/dev/null || true
  "${APP_BINARY}" --defaults-suite="${DEFAULTS_SUITE}" "$@" >> "${LOG_FILE}" 2>&1 &
  APP_PID=$!
}

stop_app() {
  if [[ -n "${APP_PID}" ]]; then kill "${APP_PID}" 2>/dev/null || true; wait "${APP_PID}" 2>/dev/null || true; fi
  APP_PID=""
  pkill -f "${LAUNCH_LINKS}/" 2>/dev/null || true
  sleep 1
}

log_size() {
  if [[ -f "${EMULATOR_LOG}" ]]; then stat -f %z "${EMULATOR_LOG}"; else echo 0; fi
}

# Emulator log written since byte offset $1.
log_since() {
  if [[ -f "${EMULATOR_LOG}" ]]; then tail -c +"$(( $1 + 1 ))" "${EMULATOR_LOG}"; fi
}

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
if [[ ! -f "${LIBRARY}/library.json" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "No ${LIBRARY}/library.json. Download the library first." 2
fi
for rom in apple2plus.rom apple2e-enhanced.rom apple2e-video.rom; do
  if [[ ! -f "${HOME}/Library/Application Support/Apple2Forge/roms/${rom}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "ROM ${rom} is not installed; run tools/05_fetch_rom.sh --install (and --model=iie)." 2
  fi
done
pass_gate "Gate 0: Inputs" "${gate_start}"

# ── Gate A1: build ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate A1] Build, ROM check and signature"
if ! bash "${REPO_ROOT}/tools/60_build_app.sh" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate A1: Build" "${gate_start}" "tools/60_build_app.sh failed; see ${LOG_FILE}."
fi
if ! codesign --verify --strict --deep "${APP}" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate A1: Build" "${gate_start}" "codesign --verify failed."
fi
pass_gate "Gate A1: Build" "${gate_start}"

# ── Gate A2: menu matches the catalog ───────────────────────────────
gate_start="$(date +%s)"
echo "[Gate A2] Library menu matches library.json"
app_cli --library="${LIBRARY}" --dump-menu > "${WORK}/menu.txt" 2>> "${LOG_FILE}" || true
if ! python3 -I - "${LIBRARY}/library.json" "${WORK}/menu.txt" <<'PY' >> "${LOG_FILE}" 2>&1
import json, sys
catalog = json.load(open(sys.argv[1]))
expected = {}
for t in catalog["titles"]:
    if t["hidden"]:
        continue
    label = t["title"] + {"IIe128K": " — Apple //e", "noboot": " — not a startup disk"}.get(t["requirement"], "")
    expected.setdefault(t["subject"], []).append(label)
menu, subject = {}, None
for line in open(sys.argv[2], encoding="utf-8").read().splitlines():
    if line.startswith("  "):
        menu[subject].append(line[2:])
    else:
        subject = line
        menu[subject] = []
order = [s for s in catalog["subjects"] if s in expected]
problems = []
if list(menu) != order:
    problems.append(f"subjects {list(menu)} != {order}")
for s in order:
    if sorted(menu.get(s, [])) != sorted(expected[s]):
        problems.append(f"{s}: {len(menu.get(s, []))} menu items vs {len(expected[s])} visible titles")
print("\n".join(problems) or f"menu OK: {sum(len(v) for v in menu.values())} titles in {len(menu)} subjects")
sys.exit(1 if problems else 0)
PY
then
  fail_gate "Gate A2: Menu" "${gate_start}" "The menu does not match library.json; see ${LOG_FILE}."
fi
pass_gate "Gate A2: Menu" "${gate_start}"

# ── Gate A3: one-disk title starts ──────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate A3] A one-disk title opens its own a2emu window"
one_disk=()
while IFS= read -r line; do one_disk+=("${line}"); done < <(pick_title one-disk)
echo "  title: ${one_disk[1]}" | tee -a "${LOG_FILE}"
offset="$(log_size)"
start_app --library="${LIBRARY}" --launch="${one_disk[0]}"
sleep "${START_WAIT_SECONDS}"
emu_pid="$(pgrep -f "${LAUNCH_LINKS}/${one_disk[1]}" | head -1 || true)"
windows=""
if [[ -n "${emu_pid}" ]]; then windows="$(swift "${WINDOW_LIST}" "${emu_pid}" 2>> "${LOG_FILE}" || true)"; fi
if [[ -n "${windows}" ]]; then
  screencapture -x -o -l "${windows%% *}" "${OUT_DIR}/a3_title.png" 2>> "${LOG_FILE}" || true
fi
a3_log="$(log_since "${offset}")"
stop_app
if [[ -z "${emu_pid}" || -z "${windows}" ]]; then
  fail_gate "Gate A3: Start title" "${gate_start}" "No a2emu window named \"${one_disk[1]}\" appeared; see ${LOG_FILE} and ${EMULATOR_LOG}."
fi
if ! grep -qF "Mounted disk1: ${LIBRARY}/disks/${one_disk[2]}" <<< "${a3_log}"; then
  fail_gate "Gate A3: Start title" "${gate_start}" "a2emu did not mount ${one_disk[2]} in drive 1."
fi
pass_gate "Gate A3: Start title" "${gate_start}"

# ── Gates A4 and A5: two sides, then a Disk-menu swap ───────────────
gate_start="$(date +%s)"
echo "[Gate A4] A two-sided title mounts side A and side B"
two_sided=()
while IFS= read -r line; do two_sided+=("${line}"); done < <(pick_title two-sided)
echo "  title: ${two_sided[1]}" | tee -a "${LOG_FILE}"
offset="$(log_size)"
start_app --library="${LIBRARY}" --launch="${two_sided[0]}" \
  --swap-after="${SWAP_DELAY_SECONDS}:1:${two_sided[3]}"
sleep "${START_WAIT_SECONDS}"
a4_log="$(log_since "${offset}")"
stop_app
echo "${a4_log}" >> "${LOG_FILE}"
if ! grep -qF "Mounted disk1: ${LIBRARY}/disks/${two_sided[2]}" <<< "${a4_log}" \
  || ! grep -qF "Mounted disk2: ${LIBRARY}/disks/${two_sided[3]}" <<< "${a4_log}"; then
  fail_gate "Gate A4: Two sides" "${gate_start}" "Both sides were not mounted at start; see ${LOG_FILE}."
fi
pass_gate "Gate A4: Two sides" "${gate_start}"

gate_start="$(date +%s)"
echo "[Gate A5] Disk menu insert reaches a2emu"
if ! grep -qF "drive 1 now holds ${LIBRARY}/disks/${two_sided[3]}" <<< "${a4_log}"; then
  fail_gate "Gate A5: Disk swap" "${gate_start}" "a2emu never reported drive 1 holding ${two_sided[3]}."
fi
pass_gate "Gate A5: Disk swap" "${gate_start}"

# ── Gate A6: download into a new folder ─────────────────────────────
gate_start="$(date +%s)"
if [[ "${SKIP_DOWNLOAD}" -eq 1 ]]; then
  echo "[Gate A6] SKIPPED (--skip-download)"
  SKIPPED_GATES="${SKIPPED_GATES:-} A6"
else
  echo "[Gate A6] Download ${DOWNLOAD_LIMIT} files into an empty folder"
  fresh="${WORK}/fresh library"
  if ! app_cli --download-to="${fresh}" --limit="${DOWNLOAD_LIMIT}" >> "${LOG_FILE}" 2>&1; then
    fail_gate "Gate A6: Download" "${gate_start}" "The download pipeline failed; see ${LOG_FILE}."
  fi
  if ! python3 -I - "${fresh}" "${DOWNLOAD_LIMIT}" <<'PY' >> "${LOG_FILE}" 2>&1
import json, os, sys
folder, limit = sys.argv[1], int(sys.argv[2])
files = json.load(open(os.path.join(folder, "manifest.json")))["files"]
titles = json.load(open(os.path.join(folder, "library.json")))["titles"]
on_disk = [f for f in files if os.path.isfile(os.path.join(folder, "disks", f["path"]))]
print(f"{len(on_disk)} disks, {len(titles)} titles")
sys.exit(0 if len(on_disk) == limit and titles else 1)
PY
  then
    fail_gate "Gate A6: Download" "${gate_start}" "The new folder lacks ${DOWNLOAD_LIMIT} disks or a catalog; see ${LOG_FILE}."
  fi
  pass_gate "Gate A6: Download" "${gate_start}"
fi

# ── Gate A7: no library inside an app ───────────────────────────────
gate_start="$(date +%s)"
echo "[Gate A7] A folder inside an .app is refused"
if app_cli --set-library="${APP}/Contents/library" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate A7: App-bundle folder" "${gate_start}" "The app accepted a folder inside ${APP}."
fi
if [[ -e "${APP}/Contents/library" ]] || ! codesign --verify --strict --deep "${APP}" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate A7: App-bundle folder" "${gate_start}" "Something was written inside the app bundle."
fi
pass_gate "Gate A7: App-bundle folder" "${gate_start}"

# ── Gate A8: the choice is remembered ───────────────────────────────
gate_start="$(date +%s)"
echo "[Gate A8] The chosen folder is remembered across launches"
chosen="${WORK}/chosen library"
app_cli --set-library="${chosen}" >> "${LOG_FILE}" 2>&1 || true
remembered="$(app_cli --print-library 2>> "${LOG_FILE}" || true)"
if [[ "$(cd "${chosen}" 2>/dev/null && pwd -P)" != "$(cd "${remembered}" 2>/dev/null && pwd -P)" ]]; then
  fail_gate "Gate A8: Remembered" "${gate_start}" "Expected ${chosen}, the next launch reported \"${remembered}\"."
fi
pass_gate "Gate A8: Remembered" "${gate_start}"

if [[ -n "${SKIPPED_GATES:-}" ]]; then
  print_summary "PASSED (skipped:${SKIPPED_GATES})"
else
  print_summary "PASSED"
fi
