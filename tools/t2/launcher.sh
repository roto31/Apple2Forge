#!/bin/bash
set -euo pipefail

# T2-hybrid app launcher (CFBundleExecutable). Replaces itself with the bundled
# a2n-t2 (the game recompiled to C, with a 6502 interpreter for code no
# recorded session reached) so the window belongs to this app. Needs no ROM;
# if the operator's Apple II+ ROM is installed it is passed along so ROM code
# the game reaches outside the recompiled set runs from the real bytes.
# Exit codes: 0 never (exec), 1 bundle damaged.

readonly CONTENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ENGINE="${CONTENTS_DIR}/MacOS/a2n-t2"
readonly DISK="${CONTENTS_DIR}/Resources/disk.dsk"
readonly START_IMAGE="${CONTENTS_DIR}/Resources/start/start"
readonly ROM_FILE="${HOME}/Library/Application Support/Apple2Forge/roms/apple2plus.rom"
readonly ROM_SIZE_BYTES=12288
readonly APP_NAME="$(/usr/bin/defaults read "${CONTENTS_DIR}/Info" CFBundleName 2>/dev/null || echo "This app")"
readonly LOG_DIR="${HOME}/Library/Logs/Apple2Forge"
readonly LOG_FILE="${LOG_DIR}/$(basename "$(dirname "${CONTENTS_DIR}")" .app).log"
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

# Only engine options the test gate needs are passed through; anything else
# (including anything LaunchServices adds) is dropped.
passthrough_args=()
for arg in "$@"; do
  case "${arg}" in
    --frames=*|--headless|--probe=*|--probe-out=*|--no-sound|--hash-frames=*|--key-file=*|--t2-stats=*) passthrough_args+=("${arg}") ;;
    *) ;;
  esac
done

mkdir -p "${LOG_DIR}"
if [[ -f "${LOG_FILE}" && "$(/usr/bin/stat -f %z "${LOG_FILE}")" -gt "${LOG_ROTATE_BYTES}" ]]; then
  mv -f "${LOG_FILE}" "${LOG_FILE}.old"
fi
echo "=== $(date '+%Y-%m-%d %H:%M:%S %z') launch ${CONTENTS_DIR%/Contents}" >> "${LOG_FILE}"

for needed in "${ENGINE}" "${DISK}" "${START_IMAGE}" "${START_IMAGE}.regs" "${START_IMAGE}.lc" "${START_IMAGE}.disk" "${START_IMAGE}.blanked"; do
  if [[ ! -r "${needed}" ]]; then
    echo "ERROR: missing ${needed}" >> "${LOG_FILE}"
    show_alert "This app is damaged (missing ${needed##*/Contents/}). Rebuild it with tools/55_wrap_t2.sh."
    exit 1
  fi
done

rom_args=()
if [[ -r "${ROM_FILE}" ]]; then
  rom_size="$(/usr/bin/stat -f %z "${ROM_FILE}")"
  if [[ "${rom_size}" -eq "${ROM_SIZE_BYTES}" ]]; then
    rom_args+=("--rom=${ROM_FILE}")
  else
    echo "WARN: ignoring ROM at ${ROM_FILE}: ${rom_size} bytes, expected ${ROM_SIZE_BYTES}" >> "${LOG_FILE}"
  fi
fi

# ${arr[@]+...} keeps bash 3.2 quiet about an empty array under set -u.
exec "${ENGINE}" --restore="${START_IMAGE}" --disk1="${DISK}" \
  ${rom_args[@]+"${rom_args[@]}"} ${passthrough_args[@]+"${passthrough_args[@]}"} 2>>"${LOG_FILE}"
