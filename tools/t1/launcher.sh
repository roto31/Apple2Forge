#!/bin/bash
set -euo pipefail

# T1 app launcher (CFBundleExecutable). Finds the operator's Apple II ROM,
# then replaces itself with the bundled a2emu so the emulator window belongs
# to this app. No ROM is inside the app; without one it shows an alert.
# Exit codes: 0 never (exec), 1 ROM missing or unreadable.

readonly CONTENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly EMULATOR="${CONTENTS_DIR}/MacOS/a2emu"
readonly DISK="${CONTENTS_DIR}/Resources/disk.dsk"
readonly ROM_FILE="${HOME}/Library/Application Support/Apple2Forge/roms/apple2plus.rom"
readonly ROM_SIZE_BYTES=12288
readonly APP_NAME="$(/usr/bin/defaults read "${CONTENTS_DIR}/Info" CFBundleName 2>/dev/null || echo "This app")"
readonly LOG_DIR="${HOME}/Library/Logs/Apple2Forge"
readonly LOG_FILE="${LOG_DIR}/$(basename "$(dirname "${CONTENTS_DIR}")" .app).log"
# a2emu logs every unemulated slot-ROM read, a few thousand lines per boot.
readonly LOG_ROTATE_BYTES=1048576

show_alert() {
  local message="$1"
  # Automated tests set this so a modal alert does not block the run.
  if [[ "${A2N_SUPPRESS_ALERT:-0}" == "1" ]]; then return; fi
  /usr/bin/osascript - "${APP_NAME}" "${message}" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display alert (item 1 of argv) message (item 2 of argv) as critical buttons {"OK"} default button "OK"
end run
APPLESCRIPT
}

# Only emulator options the test gate needs, --display=classic|smooth and
# --controls=fade|always|hidden are passed through; anything else (including
# anything LaunchServices adds) is dropped.
passthrough_args=()
for arg in "$@"; do
  case "${arg}" in
    --frames=*|--snapshot-at=*|--snapshot-out=*|--probe=*|--probe-out=*|--no-sound|--display=*|--controls=*) passthrough_args+=("${arg}") ;;
    *) ;;
  esac
done

mkdir -p "${LOG_DIR}"
if [[ -f "${LOG_FILE}" && "$(/usr/bin/stat -f %z "${LOG_FILE}")" -gt "${LOG_ROTATE_BYTES}" ]]; then
  mv -f "${LOG_FILE}" "${LOG_FILE}.old"
fi
echo "=== $(date '+%Y-%m-%d %H:%M:%S %z') launch ${CONTENTS_DIR%/Contents}" >> "${LOG_FILE}"

if [[ ! -r "${ROM_FILE}" ]]; then
  echo "ERROR: ROM not found at ${ROM_FILE}" >> "${LOG_FILE}"
  show_alert "Apple II ROM not found.

This app does not include Apple's ROM. Put your Apple II+ ROM (12,288 bytes) at:
~/Library/Application Support/Apple2Forge/roms/apple2plus.rom

From the build project you can run: tools/05_fetch_rom.sh --install"
  exit 1
fi
rom_size="$(/usr/bin/stat -f %z "${ROM_FILE}")"
if [[ "${rom_size}" -ne "${ROM_SIZE_BYTES}" ]]; then
  echo "ERROR: ROM is ${rom_size} bytes, expected ${ROM_SIZE_BYTES}" >> "${LOG_FILE}"
  show_alert "The Apple II ROM file is ${rom_size} bytes; an Apple II+ ROM is ${ROM_SIZE_BYTES} bytes.

Replace ~/Library/Application Support/Apple2Forge/roms/apple2plus.rom with a correct copy."
  exit 1
fi

# ${arr[@]+...} keeps bash 3.2 quiet about an empty array under set -u.
exec "${EMULATOR}" --rom="${ROM_FILE}" --disk1="${DISK}" ${passthrough_args[@]+"${passthrough_args[@]}"} 2>>"${LOG_FILE}"
