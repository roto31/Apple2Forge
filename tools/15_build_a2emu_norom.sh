#!/bin/bash
set -euo pipefail

# Stage 2B: build a2emu with no Apple ROM inside it, plus a Language Card.
# Exports the pinned apple2tc source to vendor/apple2tc-norom-src/, applies
# the patches in PATCH_FILES (a2emu then needs --rom=PATH, has 64K, and its
# snapshots include the Language Card and can be resumed with --restore), builds
# only the a2emu target, and proves the ROM bytes are absent from the binary.
# Output: build/a2emu-norom/a2emu (+ .sha256, BUILD_INFO.txt).
# Exit codes: 0 success, 1 gate failed, 2 config error, 3 missing dependency.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly UPSTREAM_DIR="${REPO_ROOT}/vendor/apple2tc"
readonly PIN_FILE="${REPO_ROOT}/vendor/apple2tc.COMMIT"
# Applied in this order; each is made against the tree the previous one left.
readonly PATCH_FILES=(
  "${REPO_ROOT}/vendor/patches/a2emu-require-rom.patch"
  "${REPO_ROOT}/vendor/patches/a2emu-language-card.patch"
  "${REPO_ROOT}/vendor/patches/a2emu-lc-snapshot.patch"
  "${REPO_ROOT}/vendor/patches/a2emu-disk-control.patch"
  "${REPO_ROOT}/vendor/patches/a2emu-iie.patch"
  "${REPO_ROOT}/vendor/patches/a2emu-snapshot-frame.patch"
  "${REPO_ROOT}/vendor/patches/a2emu-disk-order.patch"
  "${REPO_ROOT}/vendor/patches/a2emu-menu-bar.patch"
  "${REPO_ROOT}/vendor/patches/a2emu-smooth-display.patch"
  "${REPO_ROOT}/vendor/patches/a2emu-overlay.patch"
)
readonly SNAPSHOT_FILES_SUFFIXES=("" ".regs" ".lc" ".disk")
readonly TEXT_PAGE_TOOL="${REPO_ROOT}/tests/tools/text_page.py"
# Autostart Monitor KEYIN: the first key wait, reached once BASIC shows "]".
readonly BASIC_PROMPT_KEY_WAIT="FD1B"
readonly BASIC_BOOT_FRAMES=300
readonly SRC_DIR="${REPO_ROOT}/vendor/apple2tc-norom-src"
readonly CMAKE_BUILD_DIR="${SRC_DIR}/build"
readonly OUT_DIR="${REPO_ROOT}/build/a2emu-norom"
readonly OUT_BINARY="${OUT_DIR}/a2emu"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2plus.rom"
readonly HELP_TIMEOUT_SECONDS=10
readonly SMOKE_FRAMES=60
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/15_build_a2emu_norom.log"
SUMMARY_TITLE="Stage 2B ROM-free a2emu build"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<'EOF'
Usage: tools/15_build_a2emu_norom.sh [--dry-run] [--help]

Builds build/a2emu-norom/a2emu: apple2tc's emulator with the built-in
Apple II+ ROM removed. The result refuses to start without --rom=PATH.
Needs: Stage 0 done (vendor/apple2tc + pin), roms/apple2plus.rom (for the
"no ROM bytes inside" check; run tools/05_fetch_rom.sh first).

  --dry-run   Show what would happen; change nothing.
  --help      This text.
EOF
}

DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "ERROR: unknown option ${arg}" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "${LOG_DIR}"
echo "=== 15_build_a2emu_norom.sh $(date '+%Y-%m-%d %H:%M:%S %z')" >> "${LOG_FILE}"

# run_limited SECONDS CMD... → exit status of CMD, 142 if it hung.
run_limited() {
  local seconds="$1"; shift
  perl -e 'alarm shift; exec { $ARGV[0] } @ARGV' "${seconds}" "$@"
}

# ── Gate 0: prerequisites ───────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Prerequisites"
for tool in git cmake clang++ python3 perl shasum; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    fail_gate "Gate 0: Prerequisites" "${gate_start}" "Missing ${tool}. Run tools/00_setup.sh for the full check." 3
  fi
done
for needed in "${PIN_FILE}" "${PATCH_FILES[@]}" "${ROM_FILE}" "${TEXT_PAGE_TOOL}"; do
  if [[ ! -f "${needed}" ]]; then
    fail_gate "Gate 0: Prerequisites" "${gate_start}" "Missing ${needed#"${REPO_ROOT}"/}. Stage 0: tools/00_setup.sh; ROM: tools/05_fetch_rom.sh." 2
  fi
done
if [[ ! -d "${UPSTREAM_DIR}/.git" ]]; then
  fail_gate "Gate 0: Prerequisites" "${gate_start}" "vendor/apple2tc is not a clone. Run tools/00_setup.sh." 2
fi
PIN="$(tr -d '[:space:]' < "${PIN_FILE}")"
if ! git -C "${UPSTREAM_DIR}" cat-file -e "${PIN}^{commit}" 2>>"${LOG_FILE}"; then
  fail_gate "Gate 0: Prerequisites" "${gate_start}" "Pinned commit ${PIN} not in vendor/apple2tc. Run tools/00_setup.sh." 2
fi
echo "    pin ${PIN}"
pass_gate "Gate 0: Prerequisites" "${gate_start}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[dry-run] would: git archive ${PIN} → vendor/apple2tc-norom-src/ (replacing it)"
  for patch_file in "${PATCH_FILES[@]}"; do echo "[dry-run] would: apply ${patch_file#"${REPO_ROOT}"/}"; done
  echo "[dry-run] would: cmake configure + build target a2emu → build/a2emu-norom/a2emu"
  print_summary "PASSED (dry run)"
  exit 0
fi

# ── Gate 1: export pinned source ────────────────────────────────────
# SRC_DIR is regenerated from the pin every run; nothing in it is hand-edited.
gate_start="$(date +%s)"
echo "[Gate 1] Export pinned source"
rm -rf "${SRC_DIR}"
mkdir -p "${SRC_DIR}"
if ! git -C "${UPSTREAM_DIR}" archive --format=tar "${PIN}" | tar -x -C "${SRC_DIR}" 2>>"${LOG_FILE}"; then
  fail_gate "Gate 1: Export pinned source" "${gate_start}" "git archive failed; see log."
fi
if [[ ! -f "${SRC_DIR}/lib/engine6502/engine6502.cpp" ]]; then
  fail_gate "Gate 1: Export pinned source" "${gate_start}" "Export is missing lib/engine6502/engine6502.cpp."
fi
pass_gate "Gate 1: Export pinned source" "${gate_start}"

# ── Gate 2: apply patch ─────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 2] Apply ${#PATCH_FILES[@]} patches"
for patch_file in "${PATCH_FILES[@]}"; do
  if ! (cd "${SRC_DIR}" && patch -p1 --forward --batch < "${patch_file}") >>"${LOG_FILE}" 2>&1; then
    fail_gate "Gate 2: Apply patches" "${gate_start}" "${patch_file#"${REPO_ROOT}"/} no longer applies to ${PIN}. Re-check it against the files it names."
  fi
  echo "    applied ${patch_file##*/}"
done
if grep -q "apple2plus_rom" "${SRC_DIR}/lib/engine6502/engine6502.cpp"; then
  fail_gate "Gate 2: Apply patches" "${gate_start}" "engine6502.cpp still references apple2plus_rom after patching."
fi
if ! grep -q "powerOnLanguageCard" "${SRC_DIR}/lib/engine6502/engine6502.cpp"; then
  fail_gate "Gate 2: Apply patches" "${gate_start}" "Language Card code missing from engine6502.cpp after patching."
fi
if ! grep -q "engine_snapshot_extra" "${SRC_DIR}/lib/engine6502/engine6502.cpp" \
  || ! grep -q "engine_snapshot_extra" "${SRC_DIR}/lib/a2host/probe.c"; then
  fail_gate "Gate 2: Apply patches" "${gate_start}" "Language Card snapshot/restore code missing after patching."
fi
if ! grep -q "control-fd" "${SRC_DIR}/lib/engine6502/engine6502.cpp"; then
  fail_gate "Gate 2: Apply patches" "${gate_start}" "Disk-control (--control-fd) code missing after patching."
fi
if ! grep -q "powerOnIIe" "${SRC_DIR}/lib/engine6502/engine6502.cpp" \
  || ! grep -q "execCMOS" "${SRC_DIR}/lib/cpuemu/emu6502.cpp"; then
  fail_gate "Gate 2: Apply patches" "${gate_start}" "Apple //e (--model=iie) code missing after patching."
fi
if ! grep -q "snapshot-frame" "${SRC_DIR}/lib/a2host/a2host.c"; then
  fail_gate "Gate 2: Apply patches" "${gate_start}" "--snapshot-frame code missing after patching."
fi
if ! grep -q "is_prodos_order" "${SRC_DIR}/lib/a2io/disk2.c"; then
  fail_gate "Gate 2: Apply patches" "${gate_start}" "ProDOS sector-order detection missing after patching."
fi
if ! grep -q "NSWindowStyleMaskNonactivatingPanel" "${SRC_DIR}/include/apple2tc/sokol/sokol_app.h"; then
  fail_gate "Gate 2: Apply patches" "${gate_start}" "Non-activating emulator window (menu-bar fix) missing after patching."
fi
pass_gate "Gate 2: Apply patches" "${gate_start}"

# ── Gate 3: configure + build a2emu only ────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 3] Build a2emu (this takes a minute or two)"
cpu_count="$(sysctl -n hw.ncpu)"
if ! cmake -S "${SRC_DIR}" -B "${CMAKE_BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 3: Build a2emu" "${gate_start}" "cmake configure failed; see ${LOG_FILE#"${REPO_ROOT}"/}."
fi
if ! cmake --build "${CMAKE_BUILD_DIR}" --target a2emu -j "${cpu_count}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 3: Build a2emu" "${gate_start}" "Build failed; see ${LOG_FILE#"${REPO_ROOT}"/}."
fi
built_binary="${CMAKE_BUILD_DIR}/tools/a2emu/a2emu"
if [[ ! -x "${built_binary}" ]]; then
  fail_gate "Gate 3: Build a2emu" "${gate_start}" "Build reported success but ${built_binary} is missing."
fi
mkdir -p "${OUT_DIR}"
cp -f "${built_binary}" "${OUT_BINARY}.tmp"
mv -f "${OUT_BINARY}.tmp" "${OUT_BINARY}"
ARTIFACTS+=("build/a2emu-norom/a2emu")
pass_gate "Gate 3: Build a2emu" "${gate_start}"

# ── Gate 4: no ROM bytes in the binary ──────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 4] ROM bytes absent from binary"
if ! python3 -I - "${ROM_FILE}" "${OUT_BINARY}" <<'PY' >>"${LOG_FILE}" 2>&1
import sys
rom = open(sys.argv[1], "rb").read()
binary = open(sys.argv[2], "rb").read()
WINDOW = 256
found = [hex(0xD000 + off) for off in range(0, len(rom) - WINDOW + 1, WINDOW)
         if rom[off:off + WINDOW] in binary]
print(f"checked {len(rom) // WINDOW} ROM windows of {WINDOW} bytes; found {len(found)}: {found[:8]}")
sys.exit(1 if found else 0)
PY
then
  fail_gate "Gate 4: ROM bytes absent" "${gate_start}" "ROM content was found inside build/a2emu-norom/a2emu. Something still references apple2plus_rom; check the patch."
fi
tail -n 1 "${LOG_FILE}" | sed 's/^/    /'
pass_gate "Gate 4: ROM bytes absent" "${gate_start}"

# ── Gate 5: behaviour ───────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 5] Behaviour: --help, refuses without ROM, runs with ROM"
help_status=0
run_limited "${HELP_TIMEOUT_SECONDS}" "${OUT_BINARY}" --help >>"${LOG_FILE}" 2>&1 || help_status=$?
if [[ "${help_status}" -ne 0 ]]; then
  fail_gate "Gate 5: Behaviour" "${gate_start}" "a2emu --help exited ${help_status} (142 = hung)."
fi
no_rom_status=0
no_rom_output="$(run_limited "${HELP_TIMEOUT_SECONDS}" "${OUT_BINARY}" --headless --frames=1 2>&1)" || no_rom_status=$?
echo "${no_rom_output}" >> "${LOG_FILE}"
if [[ "${no_rom_status}" -ne 2 ]] || [[ "${no_rom_output}" != *"no Apple II ROM given"* ]]; then
  fail_gate "Gate 5: Behaviour" "${gate_start}" "Without --rom, expected exit 2 with 'no Apple II ROM given'; got exit ${no_rom_status}."
fi
with_rom_status=0
run_limited "${HELP_TIMEOUT_SECONDS}" "${OUT_BINARY}" --headless --frames="${SMOKE_FRAMES}" --rom="${ROM_FILE}" >>"${LOG_FILE}" 2>&1 || with_rom_status=$?
if [[ "${with_rom_status}" -ne 0 ]]; then
  fail_gate "Gate 5: Behaviour" "${gate_start}" "With --rom, a ${SMOKE_FRAMES}-frame headless run exited ${with_rom_status}."
fi
pass_gate "Gate 5: Behaviour" "${gate_start}"

# ── Gate 5b: ROM still boots to BASIC ───────────────────────────────
# The Language Card copies ROM in and out of $D000-$FFFF; a mistake there
# shows up first as a machine that no longer reaches the Applesoft prompt.
gate_start="$(date +%s)"
echo "[Gate 5b] No-disk boot reaches the Applesoft ] prompt"
basic_snapshot="${OUT_DIR}/.basic_boot.snap"
remove_snapshot() {
  local suffix
  for suffix in "${SNAPSHOT_FILES_SUFFIXES[@]}"; do rm -f "$1${suffix}"; done
}
remove_snapshot "${basic_snapshot}"
run_limited "${HELP_TIMEOUT_SECONDS}" "${OUT_BINARY}" --headless --no-sound --frames="${BASIC_BOOT_FRAMES}" \
  --rom="${ROM_FILE}" --snapshot-at="${BASIC_PROMPT_KEY_WAIT}" --snapshot-out="${basic_snapshot}" >>"${LOG_FILE}" 2>&1 || true
if [[ ! -f "${basic_snapshot}" ]]; then
  fail_gate "Gate 5b: BASIC boot" "${gate_start}" "The ROM never reached its key wait (\$${BASIC_PROMPT_KEY_WAIT}) in ${BASIC_BOOT_FRAMES} frames. Suspect the Language Card patch's ROM mapping."
fi
basic_screen="$(python3 -I "${TEXT_PAGE_TOOL}" "${basic_snapshot}")"
echo "${basic_screen}" >> "${LOG_FILE}"
if [[ "${basic_screen}" != *"APPLE ]["* ]] || ! echo "${basic_screen}" | grep -q '^[0-9][0-9]|]'; then
  remove_snapshot "${basic_snapshot}"
  fail_gate "Gate 5b: BASIC boot" "${gate_start}" "Screen at the first key wait lacks 'APPLE ][' or the ] prompt; the screen is in the log."
fi
pass_gate "Gate 5b: BASIC boot" "${gate_start}"

# ── Gate 5c: snapshot → restore round trip ──────────────────────────
# Restoring the Gate 5b snapshot and capturing again at the same address must
# give back the same RAM, Language Card and registers, and the restored
# machine must keep running.
gate_start="$(date +%s)"
echo "[Gate 5c] Snapshot/restore round trip"
restored_snapshot="${OUT_DIR}/.restored.snap"
remove_snapshot "${restored_snapshot}"
if [[ ! -f "${basic_snapshot}.lc" ]]; then
  remove_snapshot "${basic_snapshot}"
  fail_gate "Gate 5c: Restore round trip" "${gate_start}" "The snapshot has no .lc file; the Language Card snapshot patch is not active."
fi
run_limited "${HELP_TIMEOUT_SECONDS}" "${OUT_BINARY}" --headless --no-sound --frames="${SMOKE_FRAMES}" \
  --rom="${ROM_FILE}" --restore="${basic_snapshot}" \
  --snapshot-at="${BASIC_PROMPT_KEY_WAIT}" --snapshot-out="${restored_snapshot}" >>"${LOG_FILE}" 2>&1 || true
round_trip_ok=1
for suffix in "${SNAPSHOT_FILES_SUFFIXES[@]}"; do
  if ! cmp -s "${basic_snapshot}${suffix}" "${restored_snapshot}${suffix}"; then
    echo "    differs: snapshot${suffix}" | tee -a "${LOG_FILE}"
    round_trip_ok=0
  fi
done
remove_snapshot "${basic_snapshot}"
remove_snapshot "${restored_snapshot}"
if [[ "${round_trip_ok}" -ne 1 ]]; then
  fail_gate "Gate 5c: Restore round trip" "${gate_start}" "A restored snapshot did not reproduce the original; see the differing files above and the log."
fi
pass_gate "Gate 5c: Restore round trip" "${gate_start}"

# ── Gate 6: record build info ───────────────────────────────────────
gate_start="$(date +%s)"
(cd "${OUT_DIR}" && shasum -a 256 a2emu > a2emu.sha256)
{
  echo "a2emu (ROM-free) built $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "apple2tc pin: ${PIN}"
  for patch_file in "${PATCH_FILES[@]}"; do
    echo "patch: ${patch_file#"${REPO_ROOT}"/} sha256 $(shasum -a 256 "${patch_file}" | cut -d' ' -f1)"
  done
  echo "binary sha256: $(cut -d' ' -f1 "${OUT_DIR}/a2emu.sha256")"
} > "${OUT_DIR}/BUILD_INFO.txt"
ARTIFACTS+=("build/a2emu-norom/a2emu.sha256" "build/a2emu-norom/BUILD_INFO.txt")
pass_gate "Gate 6: Build info written" "${gate_start}"

print_artifacts
print_summary "PASSED"
