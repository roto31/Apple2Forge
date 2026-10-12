#!/bin/bash
set -euo pipefail

# Fetch the Apple II+ (default) or enhanced Apple //e system ROM chip dumps
# from the Apple II Documentation Project mirror into roms/ (Git-ignored),
# assemble the image a2emu expects, and verify it. The ROM is for local use
# only: never commit, bundle, or redistribute it.
# Exit codes: 0 success, 1 runtime failure, 2 config error, 3 missing dependency.

readonly MIRROR_ROOT="https://mirrors.apple2.org.za/Apple%20II%20Documentation%20Project/Computers/Apple%20II"
readonly CURL_TIMEOUT_SECONDS=60
readonly DIAG_TAIL_LINES=40
# Both models' Monitor RESET handlers start at $FA62.
readonly RESET_VECTOR_HEX="62fa"
readonly IIE_VIDEO_ROM_SIZE_BYTES=4096

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
WORK_ROOT="${REPO_ROOT}"
INSTALL_DIR="${HOME}/Library/Application Support/Apple2Forge/roms"

DRY_RUN=0
INSTALL=0
MODEL="iiplus"
GATE_NAMES=()
GATE_STATUS=()
GATE_SECONDS=()
ARTIFACTS=()
SCRIPT_START="$(date +%s)"

usage() {
  cat <<'EOF'
Usage: tools/05_fetch_rom.sh [--model=iiplus|iie] [--install] [--dry-run] [--help]

--model=iiplus (default)
  Downloads the six Apple II+ ROM chip dumps (341-0011..0015, 341-0020) from
  mirrors.apple2.org.za into roms/apple2plus-chips/, assembles
  roms/apple2plus.rom (12,288 bytes, $D000-$FFFF), and verifies it against the
  copy in vendor/apple2tc/rom/ when present.

--model=iie
  Downloads the enhanced Apple //e chips (342-0304-A $C000-$DFFF,
  342-0303-A $E000-$FFFF) into roms/apple2e-chips/, assembles
  roms/apple2e-enhanced.rom (16,384 bytes, $C000-$FFFF), and also keeps the
  //e video ROM (342-0265-A) as roms/apple2e-video.rom for lowercase and
  MouseText. a2emu runs it with --model=iie.

roms/ is Git-ignored.

  --install   Also copy the ROM(s) to the install folder (see --install-dir),
              where generated apps load them at launch. A different file
              already there is backed up first (.backup-YYYYMMDD_HHMMSS).
  --work-dir=DIR
              Writable folder for roms/ and work/_logs (default: repo root, or
              the app bundle's Resources when run from Apple2Forge.app).
  --install-dir=DIR
              Destination for --install (default: ~/Library/Application
              Support/Apple2Forge/roms).
  --dry-run   Show what would be downloaded; change nothing.
  --help      Show this help.

Safe to re-run: chips already present with the right size are not re-fetched.
Use only if you are entitled to use the ROM. Never redistribute it.
EOF
}

for arg in "$@"; do
  case "${arg}" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --install) INSTALL=1 ;;
    --model=iiplus|--model=iie) MODEL="${arg#--model=}" ;;
    --work-dir=*) WORK_ROOT="${arg#--work-dir=}" ;;
    --install-dir=*) INSTALL_DIR="${arg#--install-dir=}" ;;
    *) echo "ERROR: unknown option '${arg}'" >&2; usage >&2; exit 2 ;;
  esac
done

readonly WORK_ROOT
readonly ROM_DIR="${WORK_ROOT}/roms"
readonly LOG_DIR="${WORK_ROOT}/work/_logs"
readonly LOG_FILE="${LOG_DIR}/05_fetch_rom.log"
readonly INSTALL_DIR

# Chips are ordered low address → high; concatenation order matters.
if [[ "${MODEL}" == "iie" ]]; then
  readonly MIRROR_BASE="${MIRROR_ROOT}/Apple%20IIe/ROM%20Images"
  readonly CHIP_SIZE_BYTES=8192
  readonly ROM_SIZE_BYTES=16384
  readonly CHIP_FILES=(
    "Apple IIe Enhanced ROM Pages C0-DF - 342-0304-A - 1984.bin"
    "Apple IIe Enhanced ROM Pages E0-FF - 342-0303-A - 1984.bin"
  )
  readonly VIDEO_CHIP="Apple IIe Enhanced Video ROM - 342-0265-A - US 1983.bin"
  readonly CHIP_DIR="${ROM_DIR}/apple2e-chips"
  readonly ROM_NAME="apple2e-enhanced.rom"
  readonly VIDEO_ROM_NAME="apple2e-video.rom"
  readonly UPSTREAM_ROM=""
else
  readonly MIRROR_BASE="${MIRROR_ROOT}/Apple%20II%20plus/ROM%20Images"
  readonly CHIP_SIZE_BYTES=2048
  readonly ROM_SIZE_BYTES=12288
  readonly CHIP_FILES=(
    "Apple II plus ROM Pages D0-D7 - 341-0011 - Applesoft BASIC.bin"
    "Apple II plus ROM Pages D8-DF - 341-0012 - Applesoft BASIC.bin"
    "Apple II plus ROM Pages E0-E7 - 341-0013 - Applesoft BASIC.bin"
    "Apple II plus ROM Pages E8-EF - 341-0014 - Applesoft BASIC.bin"
    "Apple II plus ROM Pages F0-F7 - 341-0015 - Applesoft BASIC.bin"
    "Apple II plus ROM Pages F8-FF - 341-0020 - Autostart Monitor.bin"
  )
  readonly VIDEO_CHIP=""
  readonly CHIP_DIR="${ROM_DIR}/apple2plus-chips"
  readonly ROM_NAME="apple2plus.rom"
  readonly VIDEO_ROM_NAME=""
  readonly UPSTREAM_ROM="${REPO_ROOT}/vendor/apple2tc/rom/apple2plus.rom"
fi
readonly ROM_FILE="${ROM_DIR}/${ROM_NAME}"
readonly ROM_MANIFEST="${ROM_FILE}.sha256"
readonly INSTALLED_ROM="${INSTALL_DIR}/${ROM_NAME}"
CHIP_DIR_REL="${CHIP_DIR#"${WORK_ROOT}/"}"
readonly CHIP_DIR_REL

record_gate() { GATE_NAMES+=("$1"); GATE_STATUS+=("$2"); GATE_SECONDS+=("$3"); }

print_summary() {
  local overall="$1" i
  echo
  echo "══════════════════════════════════════════════════════════"
  echo "EXECUTION SUMMARY — ROM fetch"
  echo "──────────────────────────────────────────────────────────"
  printf "%-40s %-8s %s\n" "Step" "Status" "Duration"
  echo "──────────────────────────────────────────────────────────"
  for i in "${!GATE_NAMES[@]}"; do
    printf "%-40s %-8s %ss\n" "${GATE_NAMES[$i]}" "${GATE_STATUS[$i]}" "${GATE_SECONDS[$i]}"
  done
  echo "──────────────────────────────────────────────────────────"
  echo "Overall: ${overall} | Total time: $(( $(date +%s) - SCRIPT_START ))s"
  echo "══════════════════════════════════════════════════════════"
}

print_artifacts() {
  local item
  echo "Artifacts completed so far:"
  if [[ ${#ARTIFACTS[@]} -eq 0 ]]; then echo "  (none)"; return; fi
  for item in "${ARTIFACTS[@]}"; do echo "  - ${item}"; done
}

fail_gate() {
  local gate_name="$1" started="$2" repair="$3" exit_code="${4:-1}"
  record_gate "${gate_name}" "FAILED" "$(( $(date +%s) - started ))"
  echo "  [FAILED] ${gate_name}" >&2
  print_artifacts >&2
  echo "Diagnostics (last ${DIAG_TAIL_LINES} lines of ${LOG_FILE}):" >&2
  tail -n "${DIAG_TAIL_LINES}" "${LOG_FILE}" >&2 || true
  echo "Repair:" >&2
  echo "${repair}" >&2
  print_summary "FAILED"
  exit "${exit_code}"
}

pass_gate() {
  record_gate "$1" "PASSED" "$(( $(date +%s) - $2 ))"
  echo "  [PASSED] $1"
}

file_size() { stat -f "%z" "$1"; }
sha256_of() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
url_encode_path() { python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

expected_chip_size() {
  if [[ -n "${VIDEO_CHIP}" && "$1" == "${VIDEO_CHIP}" ]]; then
    echo "${IIE_VIDEO_ROM_SIZE_BYTES}"
  else
    echo "${CHIP_SIZE_BYTES}"
  fi
}

ALL_CHIPS=("${CHIP_FILES[@]}")
if [[ -n "${VIDEO_CHIP}" ]]; then ALL_CHIPS+=("${VIDEO_CHIP}"); fi

# Copies $1 to $2 through a .tmp file, first backing up a different $2.
install_file() {
  local source_path="$1" target_path="$2" gate_name="$3" started="$4" backup
  local source_sha
  source_sha="$(sha256_of "${source_path}")"
  if [[ -f "${target_path}" && "$(sha256_of "${target_path}")" == "${source_sha}" ]]; then
    echo "    already installed and identical: ${target_path##*/}"
    return
  fi
  if [[ -f "${target_path}" ]]; then
    backup="${target_path}.backup-$(date +%Y%m%d_%H%M%S)"
    cp -p "${target_path}" "${backup}"
    if [[ "$(sha256_of "${backup}")" != "$(sha256_of "${target_path}")" ]]; then
      fail_gate "${gate_name}" "${started}" "Backup of ${target_path} did not verify; nothing was replaced."
    fi
    echo "    backed up existing file → ${backup}"
    ARTIFACTS+=("${backup}")
  fi
  cp -f "${source_path}" "${target_path}.tmp"
  mv -f "${target_path}.tmp" "${target_path}"
  if [[ "$(sha256_of "${target_path}")" != "${source_sha}" ]]; then
    fail_gate "${gate_name}" "${started}" "Installed copy ${target_path} does not match its source. Re-run with --install."
  fi
  ARTIFACTS+=("${target_path}")
}

mkdir -p "${LOG_DIR}"
echo "=== 05_fetch_rom.sh $(date '+%Y-%m-%d %H:%M:%S %z') model=${MODEL} dry_run=${DRY_RUN}" >> "${LOG_FILE}"

# ── Gate 0: dependencies ────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Dependencies"
for tool in curl shasum python3; do
  if ! command -v "${tool}" >/dev/null; then
    fail_gate "Gate 0: Dependencies" "${gate_start}" "Install ${tool} (xcode-select --install / brew install ${tool})." 3
  fi
done
pass_gate "Gate 0: Dependencies" "${gate_start}"

# ── Gate 1: download chip dumps ─────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 1] Download ${#ALL_CHIPS[@]} chip dumps (${MODEL})"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  for chip in "${ALL_CHIPS[@]}"; do echo "    would fetch: ${chip}"; done
  record_gate "Gate 1: Download chips" "DRY-RUN" 0
else
  mkdir -p "${CHIP_DIR}"
  for chip in "${ALL_CHIPS[@]}"; do
    chip_path="${CHIP_DIR}/${chip}"
    if [[ -f "${chip_path}" && "$(file_size "${chip_path}")" -eq "$(expected_chip_size "${chip}")" ]]; then
      echo "    present: ${chip}"
      continue
    fi
    chip_url="${MIRROR_BASE}/$(url_encode_path "${chip}")"
    echo "    fetching: ${chip}"
    echo "GET ${chip_url}" >> "${LOG_FILE}"
    if ! curl -fsSL --max-time "${CURL_TIMEOUT_SECONDS}" -o "${chip_path}.tmp" "${chip_url}" >> "${LOG_FILE}" 2>&1; then
      rm -f "${chip_path}.tmp"
      fail_gate "Gate 1: Download chips" "${gate_start}" \
        "Download failed. Check the URL in a browser:
  ${chip_url}"
    fi
    mv "${chip_path}.tmp" "${chip_path}"
  done
  ARTIFACTS+=("${CHIP_DIR_REL}/ (${#ALL_CHIPS[@]} files)")
  pass_gate "Gate 1: Download chips" "${gate_start}"
fi

# ── Gate 2: chip sizes ──────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 2] Chip sizes = ${CHIP_SIZE_BYTES} bytes"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  record_gate "Gate 2: Chip sizes" "DRY-RUN" 0
else
  for chip in "${ALL_CHIPS[@]}"; do
    chip_size="$(file_size "${CHIP_DIR}/${chip}")"
    expected_size="$(expected_chip_size "${chip}")"
    echo "chip ${chip}: ${chip_size} bytes sha256=$(sha256_of "${CHIP_DIR}/${chip}")" >> "${LOG_FILE}"
    if [[ "${chip_size}" -ne "${expected_size}" ]]; then
      fail_gate "Gate 2: Chip sizes" "${gate_start}" \
        "${chip} is ${chip_size} bytes (expected ${expected_size}). Delete it and re-run:
  rm \"${CHIP_DIR_REL}/${chip}\" && tools/05_fetch_rom.sh --model=${MODEL}"
    fi
  done
  pass_gate "Gate 2: Chip sizes" "${gate_start}"
fi

# ── Gate 3: assemble the system ROM image ───────────────────────────
gate_start="$(date +%s)"
echo "[Gate 3] Assemble roms/${ROM_NAME}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  record_gate "Gate 3: Assemble ROM" "DRY-RUN" 0
else
  chip_paths=()
  for chip in "${CHIP_FILES[@]}"; do chip_paths+=("${CHIP_DIR}/${chip}"); done
  cat "${chip_paths[@]}" > "${ROM_FILE}.tmp"
  mv "${ROM_FILE}.tmp" "${ROM_FILE}"
  rom_size="$(file_size "${ROM_FILE}")"
  if [[ "${rom_size}" -ne "${ROM_SIZE_BYTES}" ]]; then
    fail_gate "Gate 3: Assemble ROM" "${gate_start}" "Assembled ROM is ${rom_size} bytes, expected ${ROM_SIZE_BYTES}."
  fi
  # 6502 RESET vector lives at $FFFC.
  reset_vector="$(xxd -s $(( ROM_SIZE_BYTES - 4 )) -l 2 -p "${ROM_FILE}")"
  echo "reset vector bytes: ${reset_vector}" >> "${LOG_FILE}"
  if [[ "${reset_vector}" != "${RESET_VECTOR_HEX}" ]]; then
    fail_gate "Gate 3: Assemble ROM" "${gate_start}" \
      "RESET vector is ${reset_vector}, expected ${RESET_VECTOR_HEX} (\$FA62). Chip order or content is wrong."
  fi
  echo "    ${rom_size} bytes, RESET vector \$FA62"
  ARTIFACTS+=("roms/${ROM_NAME}")
  if [[ -n "${VIDEO_CHIP}" ]]; then
    cp -f "${CHIP_DIR}/${VIDEO_CHIP}" "${ROM_DIR}/${VIDEO_ROM_NAME}.tmp"
    mv -f "${ROM_DIR}/${VIDEO_ROM_NAME}.tmp" "${ROM_DIR}/${VIDEO_ROM_NAME}"
    ARTIFACTS+=("roms/${VIDEO_ROM_NAME}")
  fi
  pass_gate "Gate 3: Assemble ROM" "${gate_start}"
fi

# ── Gate 4: cross-check against upstream copy ───────────────────────
gate_start="$(date +%s)"
echo "[Gate 4] Cross-check with upstream copy"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  record_gate "Gate 4: Cross-check upstream" "DRY-RUN" 0
elif [[ -z "${UPSTREAM_ROM}" ]]; then
  echo "    upstream ships no ${MODEL} ROM — nothing to cross-check"
  record_gate "Gate 4: Cross-check upstream" "SKIPPED" 0
elif [[ ! -f "${UPSTREAM_ROM}" ]]; then
  echo "    upstream copy not present (run tools/00_setup.sh) — cannot cross-check"
  record_gate "Gate 4: Cross-check upstream" "SKIPPED" 0
else
  rom_sha="$(sha256_of "${ROM_FILE}")"
  upstream_sha="$(sha256_of "${UPSTREAM_ROM}")"
  echo "assembled=${rom_sha} upstream=${upstream_sha}" >> "${LOG_FILE}"
  if [[ "${rom_sha}" != "${upstream_sha}" ]]; then
    cmp -l "${ROM_FILE}" "${UPSTREAM_ROM}" 2>/dev/null | head -n 20 >> "${LOG_FILE}" || true
    fail_gate "Gate 4: Cross-check upstream" "${gate_start}" \
      "Assembled ROM differs from upstream's Apple II+ ROM (first differing bytes are in the log).
  It may be a different revision. Do not use it until the difference is explained."
  fi
  echo "    identical (sha256 ${rom_sha:0:16}…)"
  pass_gate "Gate 4: Cross-check upstream" "${gate_start}"
fi

# ── Gate 5: record checksum ─────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 5] Record checksum"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  record_gate "Gate 5: Record checksum" "DRY-RUN" 0
else
  (cd "${ROM_DIR}" && shasum -a 256 "${ROM_NAME}") > "${ROM_MANIFEST}.tmp"
  mv "${ROM_MANIFEST}.tmp" "${ROM_MANIFEST}"
  if ! (cd "${ROM_DIR}" && shasum -a 256 -c "${ROM_NAME}.sha256" >> "${LOG_FILE}" 2>&1); then
    fail_gate "Gate 5: Record checksum" "${gate_start}" "Checksum file does not verify. Re-run the script."
  fi
  ARTIFACTS+=("roms/${ROM_NAME}.sha256")
  pass_gate "Gate 5: Record checksum" "${gate_start}"
fi

# ── Gate 6: install for apps (optional) ─────────────────────────────
gate_start="$(date +%s)"
if [[ "${INSTALL}" -eq 1 ]]; then
  echo "[Gate 6] Install to ${INSTALL_DIR}/"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "    would copy roms/${ROM_NAME} → ${INSTALLED_ROM}"
    if [[ -n "${VIDEO_ROM_NAME}" ]]; then echo "    would copy roms/${VIDEO_ROM_NAME} → ${INSTALL_DIR}/"; fi
    record_gate "Gate 6: Install ROM" "DRY-RUN" 0
  else
    mkdir -p "${INSTALL_DIR}"
    install_file "${ROM_FILE}" "${INSTALLED_ROM}" "Gate 6: Install ROM" "${gate_start}"
    if [[ -n "${VIDEO_ROM_NAME}" ]]; then
      install_file "${ROM_DIR}/${VIDEO_ROM_NAME}" "${INSTALL_DIR}/${VIDEO_ROM_NAME}" "Gate 6: Install ROM" "${gate_start}"
    fi
    pass_gate "Gate 6: Install ROM" "${gate_start}"
  fi
fi

echo
print_artifacts
if [[ "${DRY_RUN}" -eq 1 ]]; then print_summary "DRY-RUN"; else print_summary "PASSED"; fi
exit 0
