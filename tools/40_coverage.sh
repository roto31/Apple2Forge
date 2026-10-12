#!/bin/bash
set -euo pipefail

# Stage 4 coverage: replay every scripted session in tests/fixtures/stage4/
# (and any other --sessions folders, e.g. the Stage 5 level clears)
# headless, collect the code each one executes, and merge them into a coverage
# report (percent of the disk-loaded range executed, unreached code ranges).
# No human play needed. Output stays under work/ (Git-ignored).
# Exit codes: 0 success, 1 gate failed, 2 config error, 3 missing dependency.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DEFAULT_DISK="${REPO_ROOT}/MECC-A170 Number Munchers v1.3 (4am crack)/MECC-A170 Number Munchers v1.3 (4am crack).dsk"
readonly DEFAULT_BINARY="${REPO_ROOT}/build/a2emu-norom/a2emu"
readonly DEFAULT_SESSIONS="${REPO_ROOT}/tests/fixtures/stage4"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2plus.rom"
readonly SESSION_TOOL="${REPO_ROOT}/tools/lib/coverage_session.py"
readonly REPORT_TOOL="${REPO_ROOT}/tools/lib/coverage_report.py"
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/40_coverage.log"
SUMMARY_TITLE="Stage 4 coverage"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<'EOF'
Usage: tools/40_coverage.sh [--disk PATH] [--binary PATH] [--sessions DIR]... [--jobs N] [--out DIR] [--dry-run]

Replays each *.session file headless (keys are delivered when the game polls
the keyboard, so replays are exact), then writes coverage.json / coverage.md.
  --disk PATH      default: the Number Munchers .dsk in the repo root folder
  --binary PATH    default: build/a2emu-norom/a2emu
  --sessions DIR   repeatable; default: tests/fixtures/stage4
  --jobs N         sessions replayed at once (default 1); each session is still exact
  --out DIR        default: work/<disk-slug>/coverage
  --dry-run        list the sessions; run nothing
EOF
}

disk="${DEFAULT_DISK}"
binary="${DEFAULT_BINARY}"
sessions_dirs=()
out_dir=""
jobs=1
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --disk) disk="${2:?--disk needs a path}"; shift 2 ;;
    --binary) binary="${2:?--binary needs a path}"; shift 2 ;;
    --sessions) sessions_dirs+=("${2:?--sessions needs a folder}"); shift 2 ;;
    --out) out_dir="${2:?--out needs a folder}"; shift 2 ;;
    --jobs) jobs="${2:?--jobs needs a number}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ ! "${jobs}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --jobs needs a positive number" >&2; exit 2
fi
if [[ -z "${out_dir}" ]]; then
  out_dir="${REPO_ROOT}/work/$(disk_slug "${disk}")/coverage"
fi
if [[ ${#sessions_dirs[@]} -eq 0 ]]; then
  sessions_dirs=("${DEFAULT_SESSIONS}")
fi
session_files=()
for sessions_dir in "${sessions_dirs[@]}"; do
  for session_file in "${sessions_dir}"/*.session; do
    if [[ -f "${session_file}" ]]; then session_files+=("${session_file}"); fi
  done
done

if [[ "${dry_run}" -eq 1 ]]; then
  echo "Would replay ${#session_files[@]} sessions from ${sessions_dirs[*]} into ${out_dir}:"
  for session_file in "${session_files[@]}"; do echo "  $(basename "${session_file}" .session)"; done
  exit 0
fi

mkdir -p "${LOG_DIR}"
echo "=== 40_coverage.sh $(date '+%Y-%m-%d %H:%M:%S %z') disk=${disk} out=${out_dir}" >> "${LOG_FILE}"

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
for needed in "${disk}" "${binary}" "${ROM_FILE}" "${SESSION_TOOL}" "${REPORT_TOOL}"; do
  if [[ ! -r "${needed}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${needed}. Build: tools/15_build_a2emu_norom.sh; ROM: tools/05_fetch_rom.sh --install." 2
  fi
done
if ! command -v python3 >/dev/null; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "python3 not found." 3
fi
if [[ ${#session_files[@]} -eq 0 ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "No *.session files in ${sessions_dirs[*]}." 2
fi
rm -rf "${out_dir}"
mkdir -p "${out_dir}/sessions"
pass_gate "Gate 0: Inputs" "${gate_start}"

# ── Gate 1: sessions ────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 1] Replay ${#session_files[@]} sessions (${jobs} at a time)"
# Each session logs to its own file, appended to the main log when it ends.
run_session() {
  local session_file="$1" name
  name="$(basename "${session_file}" .session)"
  mkdir -p "${out_dir}/sessions/${name}"
  python3 -I "${SESSION_TOOL}" "${session_file}" "${out_dir}/sessions/${name}" \
    "${binary}" "${ROM_FILE}" "${disk}" >"${out_dir}/sessions/${name}.log" 2>&1
}
pids=()
names=()
failed=()
reap_oldest() {
  if ! wait "${pids[0]}"; then failed+=("${names[0]}"); fi
  cat "${out_dir}/sessions/${names[0]}.log" >> "${LOG_FILE}"
  echo "    ${names[0]}"
  pids=("${pids[@]:1}")
  names=("${names[@]:1}")
}
for session_file in "${session_files[@]}"; do
  if [[ ${#pids[@]} -ge "${jobs}" ]]; then reap_oldest; fi
  run_session "${session_file}" &
  pids+=("$!")
  names+=("$(basename "${session_file}" .session)")
done
while [[ ${#pids[@]} -gt 0 ]]; do reap_oldest; done
if [[ ${#failed[@]} -gt 0 ]]; then
  fail_gate "Gate 1: Sessions" "${gate_start}" "Failed: ${failed[*]}; see ${out_dir}/sessions/<name>.log. Re-run one: python3 -I tools/lib/coverage_session.py <session> /tmp/<name> ${binary} ${ROM_FILE} <disk>"
fi
ARTIFACTS+=("${out_dir}/sessions/")
pass_gate "Gate 1: Sessions" "${gate_start}"

# ── Gate 2: report ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 2] Coverage report"
if ! python3 -I "${REPORT_TOOL}" "${out_dir}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 2: Report" "${gate_start}" "tools/lib/coverage_report.py failed; see log."
fi
echo "    $(sed -n 's/^- \*\*\([0-9.]*%\)\*\* of the \([0-9]*\) bytes.*/\1 of \2 loaded bytes executed/p' "${out_dir}/coverage.md")"
ARTIFACTS+=("${out_dir}/coverage.json" "${out_dir}/coverage.md")
pass_gate "Gate 2: Report" "${gate_start}"

print_artifacts
print_summary "PASSED"
