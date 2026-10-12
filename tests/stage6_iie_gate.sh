#!/bin/bash
set -euo pipefail

# Stage 6a gate: a2emu --model=iie is an enhanced Apple //e with 128K.
#   I1  No-disk boot reaches the Applesoft ] prompt under the "Apple //e"
#       banner (the 65C02 runs the enhanced ROM, internal $C100-$CFFF ROM).
#   I2  Auxiliary memory: a program writes $AA to aux $6000 (RAMWRT) and $55 to
#       main $6000, reads both back (RAMRD), runs 65C02 PHX/PLX, and checks
#       decimal-mode ADC sets N and Z from the result (ProDOS 8 2.x tests it).
#   I3  PR#3 turns on the 80-column firmware: 80COL and 80STORE set, and the
#       printed line reads correctly interleaved from aux and main.
#   I4  Neither //e ROM's bytes are inside the a2emu binary.
# Needs tools/05_fetch_rom.sh --model=iie (ROMs are never committed).
# Exit codes: 0 PASS, 1 gate failed, 2 config error.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly EMULATOR="${REPO_ROOT}/build/a2emu-norom/a2emu"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2e-enhanced.rom"
readonly VIDEO_ROM_FILE="${REPO_ROOT}/roms/apple2e-video.rom"
readonly OUT_DIR="${REPO_ROOT}/work/_gate/stage6"
readonly RUN_FRAMES=3000
# Monitor RDKEY: the first key wait after boot.
readonly KEY_WAIT_ADDR="FD0C"
# Where the I2/I3 programs end up once they are done.
readonly DONE_ADDR="0340"
readonly ROM_WINDOW_BYTES=256
LOG_FILE="${OUT_DIR}/iie_gate.log"
SUMMARY_TITLE="Stage 6a Apple //e gate"
# shellcheck source=../tools/lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  echo "Usage: tests/stage6_iie_gate.sh [--help]"
}
for arg in "$@"; do
  case "${arg}" in
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option ${arg}" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "${OUT_DIR}"
: > "${LOG_FILE}"
readonly SNAPSHOT="${OUT_DIR}/iie.snap"

# Runs the //e headless until PC reaches $1, with keys from file $2 (or none).
run_iie() {
  local stop_addr="$1" key_file="${2:-}" key_args=()
  rm -f "${SNAPSHOT}" "${SNAPSHOT}".*
  if [[ -n "${key_file}" ]]; then key_args=(--kbd-file="${key_file}"); fi
  "${EMULATOR}" --headless --no-sound --frames="${RUN_FRAMES}" --model=iie \
    --rom="${ROM_FILE}" --video-rom="${VIDEO_ROM_FILE}" "${key_args[@]+"${key_args[@]}"}" \
    --snapshot-at="${stop_addr}" --snapshot-out="${SNAPSHOT}" >> "${LOG_FILE}" 2>&1 || true
  [[ -f "${SNAPSHOT}.main" && -f "${SNAPSHOT}.aux" && -f "${SNAPSHOT}.iie" ]]
}

# Prints the text screen from the snapshot, 80 columns when 80COL is on.
screen_text() {
  python3 -I - "${SNAPSHOT}" <<'PY'
import sys
base = sys.argv[1]
main = open(base + ".main", "rb").read()
aux = open(base + ".aux", "rb").read()
col80 = "80COL 1" in open(base + ".iie").read().splitlines()

def char(byte):
    byte &= 0x7F
    return chr(byte if byte >= 0x20 else byte + 0x40)

for row in range(24):
    offset = 0x400 + (row % 8) * 128 + (row // 8) * 40
    if col80:
        line = "".join(char(aux[offset + i]) + char(main[offset + i]) for i in range(40))
    else:
        line = "".join(char(b) for b in main[offset:offset + 40])
    print(f"{row:02d}|{line.rstrip()}")
PY
}

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
for needed in "${EMULATOR}" "${ROM_FILE}" "${VIDEO_ROM_FILE}"; do
  if [[ ! -e "${needed}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${needed}. Build: tools/15_build_a2emu_norom.sh; ROMs: tools/05_fetch_rom.sh --model=iie." 2
  fi
done
pass_gate "Gate 0: Inputs" "${gate_start}"

# ── Gate I1: boot to BASIC ──────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate I1] No-disk boot reaches ] under the Apple //e banner"
if ! run_iie "${KEY_WAIT_ADDR}"; then
  fail_gate "Gate I1: Boot" "${gate_start}" "The //e never reached its key wait (\$${KEY_WAIT_ADDR}); see ${LOG_FILE#"${REPO_ROOT}"/}."
fi
boot_screen="$(screen_text)"
echo "${boot_screen}" >> "${LOG_FILE}"
if [[ "${boot_screen}" != *"Apple //e"* ]] || ! grep -q '^[0-9][0-9]|]' <<< "${boot_screen}"; then
  fail_gate "Gate I1: Boot" "${gate_start}" "Screen lacks the 'Apple //e' banner or the ] prompt; it is in the log."
fi
if grep -q "Invalid instruction" "${LOG_FILE}"; then
  fail_gate "Gate I1: Boot" "${gate_start}" "The CPU met an opcode it does not implement; see the log."
fi
pass_gate "Gate I1: Boot" "${gate_start}"

# ── Gate I2: auxiliary memory and 65C02 ─────────────────────────────
# $0300: STA $C005 (RAMWRT on) / LDA #$AA / STA $6000 / STA $C004 /
#        LDA #$55 / STA $6000 / JSR $0110 / LDX #$07 / PHX / LDX #$00 / PLX /
#        STX $08 / SED / LDA #$99 / CLC / ADC #$01 / CLD / PHP / PLA / STA $09 /
#        JMP $0340
# $0110 (page 1, which RAMRD does not move): STA $C003 (RAMRD on) /
#        LDA $6000 / STA $C002 / STA $06 / LDA $6000 / STA $07 / RTS
gate_start="$(date +%s)"
echo "[Gate I2] Auxiliary RAM is separate from main RAM; PHX/PLX and 65C02 decimal flags"
aux_keys="${OUT_DIR}/iie_aux.keys"
cat > "${aux_keys}" <<'EOF'
CALL -151
300:8D 05 C0 A9 AA 8D 00 60 8D 04 C0 A9 55 8D 00 60 20 10 01 A2 07 DA A2 00 FA 86 08 F8 A9 99 18 69 01 D8 08 68 85 09 4C 40 03
110:8D 03 C0 AD 00 60 8D 02 C0 85 06 AD 00 60 85 07 60
300G
EOF
if ! run_iie "${DONE_ADDR}" "${aux_keys}"; then
  fail_gate "Gate I2: Aux memory" "${gate_start}" "The test program never reached \$${DONE_ADDR}; see the log."
fi
if ! python3 -I - "${SNAPSHOT}" <<'PY' >> "${LOG_FILE}" 2>&1
import sys
base = sys.argv[1]
main = open(base + ".main", "rb").read()
aux = open(base + ".aux", "rb").read()
checks = {
    "aux $6000 = $AA": aux[0x6000] == 0xAA,
    "main $6000 = $55": main[0x6000] == 0x55,
    "read via RAMRD ($06) = $AA": main[0x06] == 0xAA,
    "read main ($07) = $55": main[0x07] == 0x55,
    "PHX/PLX ($08) = $07": main[0x08] == 0x07,
    # $99 + 1 in decimal is $00: a 65C02 sets Z and clears N, a 6502 does not.
    "decimal ADC flags ($09): Z set, N clear": main[0x09] & 0x82 == 0x02,
}
for name, ok in checks.items():
    print(("ok   " if ok else "FAIL ") + name)
sys.exit(0 if all(checks.values()) else 1)
PY
then
  fail_gate "Gate I2: Aux memory" "${gate_start}" "A memory or 65C02 check failed; the results are in the log."
fi
pass_gate "Gate I2: Aux memory" "${gate_start}"

# ── Gate I3: 80 columns ─────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate I3] PR#3 gives 80 columns from interleaved aux/main text"
col80_keys="${OUT_DIR}/iie_80col.keys"
printf 'PR#3\nPRINT "hello from eighty columns"\nPOKE 832,96:CALL 832\n' > "${col80_keys}"
if ! run_iie "${DONE_ADDR}" "${col80_keys}"; then
  fail_gate "Gate I3: 80 columns" "${gate_start}" "BASIC never reached CALL 832 after PR#3; see the log."
fi
col80_screen="$(screen_text)"
echo "${col80_screen}" >> "${LOG_FILE}"
if ! grep -q '^80COL 1$' "${SNAPSHOT}.iie" || ! grep -q '^80STORE 1$' "${SNAPSHOT}.iie"; then
  fail_gate "Gate I3: 80 columns" "${gate_start}" "80COL/80STORE are not both on after PR#3."
fi
if ! grep -q '^[0-9][0-9]|hello from eighty columns$' <<< "${col80_screen}"; then
  fail_gate "Gate I3: 80 columns" "${gate_start}" "The printed line is not on the 80-column screen; the screen is in the log."
fi
pass_gate "Gate I3: 80 columns" "${gate_start}"

# ── Gate I4: no //e ROM bytes in the binary ─────────────────────────
gate_start="$(date +%s)"
echo "[Gate I4] //e ROM bytes absent from binary"
if ! python3 -I - "${EMULATOR}" "${ROM_WINDOW_BYTES}" "${ROM_FILE}" "${VIDEO_ROM_FILE}" <<'PY' >> "${LOG_FILE}" 2>&1
import sys
binary = open(sys.argv[1], "rb").read()
window = int(sys.argv[2])
found = 0
for path in sys.argv[3:]:
    rom = open(path, "rb").read()
    hits = [off for off in range(0, len(rom) - window + 1, window)
            if len(set(rom[off:off + window])) > 1 and rom[off:off + window] in binary]
    print(f"{path}: {len(hits)} of {len(rom) // window} windows found")
    found += len(hits)
sys.exit(1 if found else 0)
PY
then
  fail_gate "Gate I4: ROM bytes absent" "${gate_start}" "//e ROM content was found inside the a2emu binary."
fi
pass_gate "Gate I4: ROM bytes absent" "${gate_start}"

rm -f "${SNAPSHOT}" "${SNAPSHOT}".*
print_summary "PASSED"
