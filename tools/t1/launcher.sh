#!/bin/bash
set -euo pipefail

# T1 app launcher (CFBundleExecutable). Finds the operator's Apple II ROM(s),
# then replaces itself with the bundled a2emu so the emulator window belongs
# to this app. No ROM is inside the app; without one it shows an alert.
# Exit codes: 0 never (exec), 1 ROM missing or unreadable.

readonly CONTENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly EMULATOR="${CONTENTS_DIR}/MacOS/a2emu"
readonly RESOURCES="${CONTENTS_DIR}/Resources"
readonly DISK="${RESOURCES}/disk.dsk"
readonly DISK_SET="${RESOURCES}/disks.tsv"
readonly ROM_DIR="${HOME}/Library/Application Support/Apple2Forge/roms"
readonly ROM_FILE="${ROM_DIR}/apple2plus.rom"
readonly IIE_ROM="${ROM_DIR}/apple2e-enhanced.rom"
readonly IIE_VIDEO="${ROM_DIR}/apple2e-video.rom"
readonly ROM_SIZE_BYTES=12288
readonly IIE_ROM_SIZE=16384
readonly IIE_VIDEO_SIZE=4096
readonly APP_NAME="$(/usr/bin/defaults read "${CONTENTS_DIR}/Info" CFBundleName 2>/dev/null || echo "This app")"
readonly MACHINE="$(/usr/bin/defaults read "${CONTENTS_DIR}/Info" A2NMachine 2>/dev/null || echo "iiplus")"
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
echo "=== $(date '+%Y-%m-%d %H:%M:%S %z') launch ${CONTENTS_DIR%/Contents} machine=${MACHINE}" >> "${LOG_FILE}"

check_rom_size() {
  local path="$1" expected="$2" label="$3"
  if [[ ! -r "${path}" ]]; then
    echo "ERROR: ROM not found at ${path}" >> "${LOG_FILE}"
    show_alert "${label} not found.

Put your ROM at:
${path}

From the build project you can run: tools/05_fetch_rom.sh --install$([[ "${MACHINE}" == "iie" ]] && echo " --model=iie")"
    exit 1
  fi
  local size
  size="$(/usr/bin/stat -f %z "${path}")"
  if [[ "${size}" -ne "${expected}" ]]; then
    echo "ERROR: ROM is ${size} bytes, expected ${expected}" >> "${LOG_FILE}"
    show_alert "The ${label} is ${size} bytes; it should be ${expected} bytes.

Replace ${path} with a correct copy."
    exit 1
  fi
}

emu_args=()
if [[ "${MACHINE}" == "iie" ]]; then
  check_rom_size "${IIE_ROM}" "${IIE_ROM_SIZE}" "Apple //e ROM"
  check_rom_size "${IIE_VIDEO}" "${IIE_VIDEO_SIZE}" "Apple //e video ROM"
  emu_args+=(--model=iie "--rom=${IIE_ROM}" "--video-rom=${IIE_VIDEO}")
else
  check_rom_size "${ROM_FILE}" "${ROM_SIZE_BYTES}" "Apple II+ ROM"
  emu_args+=("--rom=${ROM_FILE}")
fi

disk1="${DISK}"
disk2=""
if [[ -f "${DISK_SET}" ]]; then
  while IFS=$'\t' read -r startup label file; do
    case "${startup}" in
      1) disk1="${RESOURCES}/${file}" ;;
      2) disk2="${RESOURCES}/${file}" ;;
    esac
  done < "${DISK_SET}"
  emu_args+=("--disk-set=${DISK_SET}")
fi

emu_args+=(--disk1="${disk1}")
[[ -n "${disk2}" ]] && emu_args+=(--disk2="${disk2}")

# ${arr[@]+...} keeps bash 3.2 quiet about an empty array under set -u.
exec "${EMULATOR}" ${emu_args[@]+"${emu_args[@]}"} ${passthrough_args[@]+"${passthrough_args[@]}"} 2>>"${LOG_FILE}"
