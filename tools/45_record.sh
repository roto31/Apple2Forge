#!/bin/bash
set -euo pipefail

# Record coverage by playing: boots DISK in an a2emu window, logs every key
# pressed (with its cycle stamp) and the code that ran, and reports how much
# code ran per memory region. --replay plays a recording back from boot; the
# run is exact, so its collected code must match the recording's.
# Output (default work/<disk-slug>/recordings/<time>/): session.keys,
# collect.json, record.json, record.md; replay adds replay-collect.json.
# Exit codes: 0 success, 1 gate failed, 2 config error, 3 missing dependency.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly EMULATOR="${REPO_ROOT}/build/a2emu-norom/a2emu"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2plus.rom"
readonly REPORT_TOOL="${REPO_ROOT}/tools/lib/record_report.py"
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/45_record.log"
SUMMARY_TITLE="Record coverage"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<'EOF'
Usage: tools/45_record.sh DISK [--out DIR] [--replay] [--keys FILE] [--frames N] [--headless]

Opens DISK in an emulator window. Play every menu and mode you want covered,
then close the window: the keys and the code that ran are saved and reported.
  --out DIR     recording folder (default work/<disk-slug>/recordings/<time>)
  --replay      play DIR/session.keys back from boot instead of recording
  --keys FILE   while recording, also type these "CYCLE CODE" keys (tests)
  --frames N    stop after N frames (tests; default: until the window closes)
  --headless    no window (tests; needs --frames)
EOF
}

disk=""
out_dir=""
replay=0
keys_file=""
frames=""
headless=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --out) out_dir="${2:?--out needs a folder}"; shift 2 ;;
    --replay) replay=1; shift ;;
    --keys) keys_file="${2:?--keys needs a file}"; shift 2 ;;
    --frames) frames="${2:?--frames needs a number}"; shift 2 ;;
    --headless) headless=1; shift ;;
    -*) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "${disk}" ]]; then echo "ERROR: only one disk image" >&2; exit 2; fi
      disk="$1"; shift ;;
  esac
done
if [[ -z "${disk}" ]]; then usage >&2; exit 2; fi
if [[ -n "${frames}" && ! "${frames}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --frames needs a positive number" >&2; exit 2
fi
if [[ "${headless}" -eq 1 && -z "${frames}" ]]; then
  echo "ERROR: --headless needs --frames" >&2; exit 2
fi
if [[ "${replay}" -eq 1 && -z "${out_dir}" ]]; then
  echo "ERROR: --replay needs --out DIR (the recording to play back)" >&2; exit 2
fi
if [[ -z "${out_dir}" ]]; then
  out_dir="${REPO_ROOT}/work/$(disk_slug "${disk}")/recordings/$(date +%Y%m%d_%H%M%S)"
fi

mkdir -p "${LOG_DIR}"
echo "=== 45_record.sh $(date '+%Y-%m-%d %H:%M:%S %z') disk=${disk} out=${out_dir} replay=${replay}" >> "${LOG_FILE}"

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
for needed in "${EMULATOR}" "${ROM_FILE}" "${REPORT_TOOL}"; do
  if [[ ! -r "${needed}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${needed#"${REPO_ROOT}"/}. Emulator: tools/15_build_a2emu_norom.sh; ROM: tools/05_fetch_rom.sh." 2
  fi
done
if [[ ! -r "${disk}" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "Cannot read disk image: ${disk}" 2
fi
if [[ -n "${keys_file}" && ! -r "${keys_file}" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "Cannot read key file: ${keys_file}" 2
fi
if [[ "${replay}" -eq 1 && ! -s "${out_dir}/session.keys" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "No recording at ${out_dir}/session.keys." 2
fi
mkdir -p "${out_dir}"
pass_gate "Gate 0: Inputs" "${gate_start}"

emulator_args=("--rom=${ROM_FILE}" "--disk1=${disk}" --collect --from-rom)
if [[ -n "${frames}" ]]; then emulator_args+=("--frames=${frames}"); fi
if [[ "${headless}" -eq 1 ]]; then emulator_args+=(--headless --no-sound); fi

# ── Gate 1: play ────────────────────────────────────────────────────
gate_start="$(date +%s)"
if [[ "${replay}" -eq 1 ]]; then
  echo "[Gate 1] Replay ${out_dir}/session.keys (close the window when it is done)"
  rm -f "${out_dir}/replay-collect.json"
  if ! "${EMULATOR}" "${emulator_args[@]}" "--key-file=${out_dir}/session.keys" \
       "--out=${out_dir}/replay-collect.json" >/dev/null 2>>"${LOG_FILE}"; then
    fail_gate "Gate 1: Replay" "${gate_start}" "a2emu failed; see ${LOG_FILE#"${REPO_ROOT}"/}."
  fi
  if [[ ! -s "${out_dir}/replay-collect.json" ]]; then
    fail_gate "Gate 1: Replay" "${gate_start}" "a2emu wrote no collect data."
  fi
  if cmp -s "${out_dir}/collect.json" "${out_dir}/replay-collect.json"; then
    echo "    replay ran exactly the recorded code"
  else
    echo "    replay ran different code from the recording (keys typed during the replay change it)"
  fi
  pass_gate "Gate 1: Replay" "${gate_start}"
  print_summary "PASSED"
  exit 0
fi

echo "[Gate 1] Record: play, then close the emulator window"
key_args=()
if [[ -n "${keys_file}" ]]; then key_args+=("--key-file=${keys_file}"); fi
rm -f "${out_dir}/collect.json" "${out_dir}/session.keys" "${out_dir}/trace.out"
if ! "${EMULATOR}" "${emulator_args[@]}" ${key_args[@]+"${key_args[@]}"} --trace-keys \
     "--out=${out_dir}/collect.json" >"${out_dir}/trace.out" 2>>"${LOG_FILE}"; then
  fail_gate "Gate 1: Record" "${gate_start}" "a2emu failed; see ${LOG_FILE#"${REPO_ROOT}"/}."
fi
# --trace-keys prints "CYCLE CODE" per key, the format --key-file reads back.
grep -E '^[0-9]+ [0-9]+$' "${out_dir}/trace.out" > "${out_dir}/session.keys" || true
rm -f "${out_dir}/trace.out"
if [[ ! -s "${out_dir}/collect.json" ]]; then
  fail_gate "Gate 1: Record" "${gate_start}" "a2emu wrote no collect data."
fi
pass_gate "Gate 1: Record" "${gate_start}"

# ── Gate 2: report ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 2] Coverage report"
if ! result="$(python3 -I "${REPORT_TOOL}" "${out_dir}" 2>&1)"; then
  fail_gate "Gate 2: Report" "${gate_start}" "${result}"
fi
echo "    ${result}"
ARTIFACTS+=("${out_dir}/record.md")
pass_gate "Gate 2: Report" "${gate_start}"

print_artifacts
print_summary "PASSED"
