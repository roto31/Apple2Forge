#!/bin/bash
set -euo pipefail

# Stage 5 recompile (T2-hybrid): turn the code the Stage 4/5 sessions executed
# into C with apple2tc --run-data --simple-c, link it into a hybrid engine
# (native C blocks, a 6502 interpreter for code the sessions never ran or the
# game rewrote), and prove it plays every session exactly like a2emu with the
# real ROM. The build holds no Apple ROM or Disk II PROM bytes.
# Everything generated stays under work/<slug>/t2build (Git-ignored): the C is
# derived from the user's disk and must not be committed.
# Exit codes: 0 success, 1 gate failed, 2 config error, 3 missing dependency.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DEFAULT_DISK="${REPO_ROOT}/MECC-A170 Number Munchers v1.3 (4am crack)/MECC-A170 Number Munchers v1.3 (4am crack).dsk"
readonly A2EMU="${REPO_ROOT}/build/a2emu-norom/a2emu"
readonly APPLE2TC="${REPO_ROOT}/vendor/apple2tc/build/tools/apple2tc/apple2tc"
readonly VENDOR_SRC="${REPO_ROOT}/vendor/apple2tc-norom-src"
readonly DISK2_SOURCE="${VENDOR_SRC}/lib/a2io/disk2.c"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2plus.rom"
readonly LIB="${REPO_ROOT}/tools/lib"
readonly T2_SOURCE="${REPO_ROOT}/t2"
# First time the game polls the keyboard on its title screen.
readonly TITLE_PC="1E95"
readonly FRAMES_TO_TITLE=1000
readonly FUZZ_SESSIONS=16
readonly FUZZ_KEYS=400
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/50_recompile.log"
SUMMARY_TITLE="Stage 5 recompile (T2-hybrid)"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<'EOF'
Usage: tools/50_recompile.sh [--disk PATH] [--jobs N] [--skip-equivalence] [--dry-run]

Needs the Stage 4 coverage output (tools/40_coverage.sh with the stage4 and
stage5 session folders) for the same disk: work/<slug>/coverage/sessions.
  --disk PATH          default: the Number Munchers 4am crack .dsk in the repo
  --jobs N             parallel apple2tc / build / replay jobs (default 4)
  --skip-equivalence   build only; do not replay the sessions
  --dry-run            print the steps; run nothing
Output: work/<slug>/t2build/cmake/a2n-t2 and work/<slug>/t2build/equivalence/.
EOF
}

disk="${DEFAULT_DISK}"
jobs=4
skip_equivalence=0
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --disk) disk="${2:?--disk needs a path}"; shift 2 ;;
    --jobs) jobs="${2:?--jobs needs a number}"; shift 2 ;;
    --skip-equivalence) skip_equivalence=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ ! "${jobs}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --jobs needs a positive number" >&2; exit 2
fi

work="${REPO_ROOT}/work/$(disk_slug "${disk}")"
sessions="${work}/coverage/sessions"
build="${work}/t2build"

if [[ "${dry_run}" -eq 1 ]]; then
  cat <<EOF
Would build ${build}:
  1. title snapshot at \$${TITLE_PC}       -> ${build}/title/title
  2. ROM-free start image           -> ${build}/start/start
  3. overlay groups from ${sessions}/*/collect.json
  4. apple2tc --run-data --simple-c per group
  5. t2_link.py                     -> ${build}/gen
  6. cmake build                    -> ${build}/cmake/a2n-t2
  7. ROM / PROM byte scan of a2n-t2
  8. equivalence over every session -> ${build}/equivalence
  9. ${FUZZ_SESSIONS} random-key sessions     -> ${build}/fuzz
EOF
  exit 0
fi

mkdir -p "${LOG_DIR}"
echo "=== 50_recompile.sh $(date '+%Y-%m-%d %H:%M:%S %z') disk=${disk}" >> "${LOG_FILE}"

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
for needed in "${disk}" "${A2EMU}" "${APPLE2TC}" "${ROM_FILE}" "${DISK2_SOURCE}" "${T2_SOURCE}/CMakeLists.txt"; do
  if [[ ! -r "${needed}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${needed}. a2emu: tools/15_build_a2emu_norom.sh; apple2tc: tools/00_setup.sh; ROM: tools/05_fetch_rom.sh --install." 2
  fi
done
for tool in python3 cmake; do
  if ! command -v "${tool}" >/dev/null; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "${tool} not found." 3
  fi
done
collects=()
for collect in "${sessions}"/*/collect.json; do
  if [[ -f "${collect}" ]]; then collects+=("${collect}"); fi
done
if [[ ${#collects[@]} -eq 0 ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "No ${sessions}/*/collect.json. Run: tools/40_coverage.sh --sessions tests/fixtures/stage4 --sessions tests/fixtures/stage5 --jobs 4" 2
fi
mkdir -p "${build}"
pass_gate "Gate 0: Inputs" "${gate_start}"

# ── Gate 1: title snapshot ──────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 1] Title-screen snapshot (first poll at \$${TITLE_PC})"
rm -rf "${build}/title"
mkdir -p "${build}/title"
if ! "${A2EMU}" --rom="${ROM_FILE}" --disk1="${disk}" --headless --no-sound --frames="${FRAMES_TO_TITLE}" \
    --snapshot-at="${TITLE_PC}" --snapshot-out="${build}/title/title" >>"${LOG_FILE}" 2>&1 ||
   ! grep -qi "^pc ${TITLE_PC}" "${build}/title/title.regs" 2>/dev/null; then
  fail_gate "Gate 1: Title snapshot" "${gate_start}" "a2emu did not reach \$${TITLE_PC} within ${FRAMES_TO_TITLE} frames; check the disk and ROM."
fi
ARTIFACTS+=("${build}/title/")
pass_gate "Gate 1: Title snapshot" "${gate_start}"

# ── Gate 2: ROM-free start image ────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 2] ROM-free start image"
rm -rf "${build}/start"
mkdir -p "${build}/start"
if ! python3 -I "${LIB}/t2_image.py" "${build}/title/title" "${ROM_FILE}" "${build}/start/start" "${DISK2_SOURCE}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 2: Start image" "${gate_start}" "ROM bytes remain in the start image (see log); extend the blanking in tools/lib/t2_image.py."
fi
ARTIFACTS+=("${build}/start/")
pass_gate "Gate 2: Start image" "${gate_start}"

# ── Gate 3: overlay groups ──────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 3] Overlay groups from ${#collects[@]} sessions"
# Probe sites must start blocks: native code only reaches the probes there.
sites="$(sed -n 's/^install [a-z]* at //p' "${sessions}"/*/session.probe | tr ',' '\n' | tr -d ' $' | sort -u | paste -sd, -)"
rm -rf "${build}/groups" "${build}/gen"
if [[ -z "${sites}" ]] ||
   ! python3 -I "${LIB}/t2_groups.py" "${build}/groups" "${ROM_FILE}" "${build}/start/start.regs" "${sites}" "${collects[@]}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 3: Groups" "${gate_start}" "tools/lib/t2_groups.py failed; see log."
fi
group_count="$(ls "${build}/groups"/g*.b33 | wc -l | tr -d ' ')"
echo "    ${group_count} groups; probe sites ${sites}"
pass_gate "Gate 3: Groups" "${gate_start}"

# ── Gate 4: apple2tc ────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 4] apple2tc --run-data --simple-c (${group_count} groups)"
failed_groups=()
pids=()
names=()
reap_oldest() {
  if ! wait "${pids[0]}" || [[ ! -s "${build}/groups/${names[0]}.c" ]]; then failed_groups+=("${names[0]}"); fi
  pids=("${pids[@]:1}")
  names=("${names[@]:1}")
}
for image in "${build}/groups"/g*.b33; do
  group="$(basename "${image}" .b33)"
  if [[ ${#pids[@]} -ge "${jobs}" ]]; then reap_oldest; fi
  "${APPLE2TC}" --run-data="${build}/groups/${group}.json" --simple-c "${image}" \
    >"${build}/groups/${group}.c" 2>"${build}/groups/${group}.err" &
  pids+=("$!")
  names+=("${group}")
done
while [[ ${#pids[@]} -gt 0 ]]; do reap_oldest; done
if [[ ${#failed_groups[@]} -gt 0 ]]; then
  fail_gate "Gate 4: apple2tc" "${gate_start}" "apple2tc failed for ${failed_groups[*]}; see ${build}/groups/<group>.err."
fi
pass_gate "Gate 4: apple2tc" "${gate_start}"

# ── Gate 5: link ────────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 5] Link blocks (byte-checked dispatch)"
if ! python3 -I "${LIB}/t2_link.py" "${build}/groups" "${build}/gen" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 5: Link" "${gate_start}" "tools/lib/t2_link.py failed; see log."
fi
echo "    $(tail -n 1 "${LOG_FILE}")"
pass_gate "Gate 5: Link" "${gate_start}"

# ── Gate 6: build ───────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 6] Build a2n-t2"
if ! cmake -S "${T2_SOURCE}" -B "${build}/cmake" -DCMAKE_BUILD_TYPE=Release \
      -DA2N_VENDOR_DIR="${VENDOR_SRC}" -DA2N_GEN_DIR="${build}/gen" >>"${LOG_FILE}" 2>&1 ||
   ! cmake --build "${build}/cmake" --target a2n-t2 -j "${jobs}" >>"${LOG_FILE}" 2>&1 ||
   [[ ! -x "${build}/cmake/a2n-t2" ]]; then
  fail_gate "Gate 6: Build" "${gate_start}" "Build failed; see log. Clean rebuild: rm -rf ${build}/cmake and re-run."
fi
ARTIFACTS+=("${build}/cmake/a2n-t2")
pass_gate "Gate 6: Build" "${gate_start}"

# ── Gate 7: no ROM bytes ────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 7] No Apple ROM / Disk II PROM bytes in a2n-t2"
if ! python3 -I "${LIB}/t2_romscan.py" "${build}/cmake/a2n-t2" "${ROM_FILE}" "${DISK2_SOURCE}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 7: ROM scan" "${gate_start}" "ROM or PROM bytes found in a2n-t2 (see log); do not ship this build."
fi
echo "    $(tail -n 1 "${LOG_FILE}")"
pass_gate "Gate 7: ROM scan" "${gate_start}"

# ── Gate 8: equivalence ─────────────────────────────────────────────
gate_start="$(date +%s)"
if [[ "${skip_equivalence}" -eq 1 ]]; then
  skip_gate "Gate 8: Equivalence" "--skip-equivalence"
else
  echo "[Gate 8] Equivalence: every session, T2 vs a2emu with the real ROM"
  rm -rf "${build}/equivalence"
  if ! python3 -I "${LIB}/t2_equiv.py" "${sessions}" "${build}/equivalence" "${A2EMU}" "${ROM_FILE}" "${disk}" \
        "${build}/title/title" "${build}/cmake/a2n-t2" "${build}/start/start" "${jobs}" 2>&1 | tee -a "${LOG_FILE}"; then
    fail_gate "Gate 8: Equivalence" "${gate_start}" "A session differs; see ${build}/equivalence/equivalence.md and <session>/{ref,t2}.out."
  fi
  ARTIFACTS+=("${build}/equivalence/equivalence.md")
  pass_gate "Gate 8: Equivalence" "${gate_start}"
fi

# ── Gate 9: random-key sessions ─────────────────────────────────────
gate_start="$(date +%s)"
if [[ "${skip_equivalence}" -eq 1 ]]; then
  skip_gate "Gate 9: Random-key sessions" "--skip-equivalence"
else
  echo "[Gate 9] ${FUZZ_SESSIONS} random-key sessions (paths no recording took), T2 vs a2emu"
  poll_sites="$(sed -n 's/^install poll at //p' "${sessions}"/*/session.probe | tr ',' '\n' | tr -d ' $' | sort -u | paste -sd, -)"
  rm -rf "${build}/fuzz"
  if ! python3 -I "${LIB}/t2_fuzz.py" "${build}/fuzz/sessions" "${A2EMU}" "${ROM_FILE}" "${disk}" "${poll_sites}" \
        "${FUZZ_SESSIONS}" "${FUZZ_KEYS}" >>"${LOG_FILE}" 2>&1 ||
     ! python3 -I "${LIB}/t2_equiv.py" "${build}/fuzz/sessions" "${build}/fuzz/equivalence" "${A2EMU}" "${ROM_FILE}" "${disk}" \
        "${build}/title/title" "${build}/cmake/a2n-t2" "${build}/start/start" "${jobs}" 2>&1 | tee -a "${LOG_FILE}"; then
    fail_gate "Gate 9: Random-key sessions" "${gate_start}" "A random-key session differs; see ${build}/fuzz/equivalence/equivalence.md."
  fi
  ARTIFACTS+=("${build}/fuzz/equivalence/equivalence.md")
  pass_gate "Gate 9: Random-key sessions" "${gate_start}"
fi

print_artifacts
print_summary "PASSED"
