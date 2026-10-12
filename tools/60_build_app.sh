#!/bin/bash
set -euo pipefail

# Stage 6: build Apple2Forge.app (the drag-and-drop build tool and the
# educational library front end). Compiles the SwiftPM package, assembles
# build/Apple2Forge.app with the ROM-free a2emu and the library scripts in
# Contents/Resources, records this project folder (whose Stage 0-5 scripts the
# build tool runs) in Info.plist unless --release, checks that no ROM bytes went in, and ad-hoc
# signs it. ROMs and disk images are never bundled.
# Exit codes: 0 success, 1 gate failed, 2 config error, 3 missing dependency.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly PACKAGE_DIR="${REPO_ROOT}/app/Apple2Forge"
readonly EMULATOR="${REPO_ROOT}/build/a2emu-norom/a2emu"
APP="${REPO_ROOT}/build/Apple2Forge.app"
readonly RELEASE_APP="${REPO_ROOT}/build/release/Apple2Forge.app"
readonly APP_VERSION="0.2.0"
readonly BUNDLE_ID="local.apple2native.Apple2Forge"
readonly MIN_MACOS="14.0"
readonly ROM_WINDOW_BYTES=256
# Copied into Contents/Resources with their repo-relative paths, so each
# script finds its helpers the same way it does in the repo.
readonly BUNDLED_FILES=(
  tools/07_fetch_edu_library.sh
  tools/50_library.sh
  tools/55_compat_sweep.sh
  tools/lib/gates.sh
  tools/lib/edu_fetch.py
  tools/lib/progress_dashboard.py
  tools/lib/library_catalog.py
  tools/lib/compat_sweep.py
  library/subject_rules.json
  library/subject_overrides.json
  library/grouping_overrides.json
)
readonly ROM_FILES=(roms/apple2plus.rom roms/apple2e-enhanced.rom roms/apple2e-video.rom)
LOG_DIR="${REPO_ROOT}/work/_gate/stage6"
LOG_FILE="${LOG_DIR}/build_app.log"
SUMMARY_TITLE="Stage 6 Apple2Forge.app build"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<EOF
Usage: tools/60_build_app.sh [--release] [--dry-run] [--help]

Builds ${APP#"${REPO_ROOT}"/} (version ${APP_VERSION}).
Needs tools/15_build_a2emu_norom.sh to have run first.
  --release  Build ${RELEASE_APP#"${REPO_ROOT}"/} for distribution: this
             project's path is not recorded, so the Build tab asks for the
             project folder in Settings, and the build fails if the path
             appears anywhere in the bundle.
  --dry-run  Check inputs only.
  --help     This text.
EOF
}

DRY_RUN=0
RELEASE=0
for arg in "$@"; do
  case "${arg}" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --release) RELEASE=1 ;;
    *) echo "ERROR: unknown option ${arg}" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ "${RELEASE}" -eq 1 ]]; then
  APP="${RELEASE_APP}"
  mkdir -p "$(dirname "${APP}")"
fi
readonly APP

mkdir -p "${LOG_DIR}"
: > "${LOG_FILE}"

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
for tool in swift codesign python3; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${tool}. Install Xcode or the command-line tools." 3
  fi
done
if [[ ! -x "${EMULATOR}" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "No ${EMULATOR}. Run tools/15_build_a2emu_norom.sh first." 2
fi
for file in "${BUNDLED_FILES[@]}"; do
  if [[ ! -f "${REPO_ROOT}/${file}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${file}." 2
  fi
done
pass_gate "Gate 0: Inputs" "${gate_start}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[dry-run] would build ${APP}"
  print_summary "PASSED"
  exit 0
fi

# ── Gate 1: compile ─────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 1] swift build -c release"
if ! swift build -c release --package-path "${PACKAGE_DIR}" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate 1: Compile" "${gate_start}" "swift build failed; see ${LOG_FILE}."
fi
binary="$(swift build -c release --package-path "${PACKAGE_DIR}" --show-bin-path)/Apple2Forge"
if [[ ! -x "${binary}" ]]; then
  fail_gate "Gate 1: Compile" "${gate_start}" "No binary at ${binary}."
fi
pass_gate "Gate 1: Compile" "${gate_start}"

# ── Gate 2: assemble ────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 2] Assemble ${APP#"${REPO_ROOT}"/}"
staging="${APP}.tmp"
rm -rf "${staging}"
mkdir -p "${staging}/Contents/MacOS" "${staging}/Contents/Resources"
cp "${binary}" "${staging}/Contents/MacOS/Apple2Forge"
cp "${EMULATOR}" "${staging}/Contents/Resources/a2emu"
if [[ "${RELEASE}" -eq 1 ]]; then
  # The debug map names the source folders, which are paths on this Mac.
  if ! strip -S -x "${staging}/Contents/MacOS/Apple2Forge" "${staging}/Contents/Resources/a2emu" >> "${LOG_FILE}" 2>&1; then
    fail_gate "Gate 2: Assemble" "${gate_start}" "strip failed; see ${LOG_FILE}."
  fi
fi
for file in "${BUNDLED_FILES[@]}"; do
  mkdir -p "${staging}/Contents/Resources/$(dirname "${file}")"
  cp "${REPO_ROOT}/${file}" "${staging}/Contents/Resources/${file}"
done
build_number="$(git -C "${REPO_ROOT}" rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "${staging}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Apple2Forge</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Apple2Forge</string>
  <key>CFBundleDisplayName</key><string>Apple2Forge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleVersion</key><string>${build_number}</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Apple II disk image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>dsk</string><string>do</string><string>po</string><string>nib</string></array>
    </dict>
  </array>
</dict>
</plist>
EOF
# Set with plutil so the path needs no XML escaping.
if [[ "${RELEASE}" -eq 0 ]]; then
  plutil -insert A2FProjectRoot -string "${REPO_ROOT}" "${staging}/Contents/Info.plist"
fi
if ! plutil -lint "${staging}/Contents/Info.plist" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate 2: Assemble" "${gate_start}" "Info.plist is not valid; see ${LOG_FILE}."
fi
if [[ -d "${APP}" ]]; then
  backup="${APP%.app}.backup-$(date +%Y%m%d_%H%M%S).app"
  mv "${APP}" "${backup}"
  echo "  previous app moved to ${backup#"${REPO_ROOT}"/}"
fi
mv "${staging}" "${APP}"
pass_gate "Gate 2: Assemble" "${gate_start}"

# ── Gate 3: no ROM or disk bytes inside ─────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 3] No ROM bytes or disk images in the bundle"
if find "${APP}" -iname '*.dsk' -o -iname '*.rom' -o -iname '*.po' -o -iname '*.woz' | grep -q .; then
  fail_gate "Gate 3: No ROMs or disks" "${gate_start}" "A disk image or ROM file is inside ${APP}."
fi
rom_args=()
for rom in "${ROM_FILES[@]}"; do
  if [[ -f "${REPO_ROOT}/${rom}" ]]; then rom_args+=("${REPO_ROOT}/${rom}"); fi
done
if [[ "${#rom_args[@]}" -gt 0 ]]; then
  if ! python3 -I - "${APP}" "${ROM_WINDOW_BYTES}" "${rom_args[@]}" <<'PY' >> "${LOG_FILE}" 2>&1
import os, sys
app, window, roms = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
blobs = []
for folder, _, files in os.walk(app):
    blobs += [open(os.path.join(folder, f), "rb").read() for f in files]
for rom in roms:
    data = open(rom, "rb").read()
    for start in range(0, len(data) - window + 1, window):
        chunk = data[start:start + window]
        if len(set(chunk)) > 4 and any(chunk in blob for blob in blobs):
            sys.exit(f"{rom} bytes {start:#x}+{window} found in the bundle")
print("no ROM windows found")
PY
  then
    fail_gate "Gate 3: No ROMs or disks" "${gate_start}" "ROM bytes are inside the bundle; see ${LOG_FILE}."
  fi
else
  echo "  WARN: no ROMs in roms/ to compare against; only file names were checked" >&2
fi
pass_gate "Gate 3: No ROMs or disks" "${gate_start}"

if [[ "${RELEASE}" -eq 1 ]]; then
  gate_start="$(date +%s)"
  echo "[Gate 3b] No local paths in the release bundle"
  if grep -rlF -e "${REPO_ROOT}" -e "${HOME}/" "${APP}" >> "${LOG_FILE}" 2>&1; then
    fail_gate "Gate 3b: No local paths" "${gate_start}" "This Mac's paths are inside ${APP}; files listed in ${LOG_FILE}."
  fi
  pass_gate "Gate 3b: No local paths" "${gate_start}"
fi

# ── Gate 4: sign ────────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 4] Ad-hoc sign and verify"
if ! codesign --force --sign - "${APP}/Contents/Resources/a2emu" >> "${LOG_FILE}" 2>&1 \
  || ! codesign --force --sign - "${APP}" >> "${LOG_FILE}" 2>&1 \
  || ! codesign --verify --strict --deep "${APP}" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate 4: Sign" "${gate_start}" "codesign failed; see ${LOG_FILE}."
fi
pass_gate "Gate 4: Sign" "${gate_start}"

echo "Built ${APP} (version ${APP_VERSION}, build ${build_number})"
print_summary "PASSED"
