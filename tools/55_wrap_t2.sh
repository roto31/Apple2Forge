#!/bin/bash
set -euo pipefail

# Stage 5: build the T2-hybrid macOS app for one disk image from the output of
# tools/50_recompile.sh. The app holds a launcher script, the a2n-t2 engine
# (game code recompiled to C + 6502 interpreter fallback), the ROM-free start
# image, a copy of the disk, the personal-use notice and third-party licenses.
# Needs no ROM; uses the operator's ROM if installed. Ad-hoc signed.
# Output: work/<disk-slug>/t2/<Name>.app
# Exit codes: 0 success, 1 gate failed, 2 config error, 3 missing dependency.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DEFAULT_DISK="${REPO_ROOT}/MECC-A170 Number Munchers v1.3 (4am crack)/MECC-A170 Number Munchers v1.3 (4am crack).dsk"
readonly LAUNCHER="${REPO_ROOT}/tools/t2/launcher.sh"
readonly NOTICE="${REPO_ROOT}/tools/t2/NOTICE.txt"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2plus.rom"
readonly DISK2_SOURCE="${REPO_ROOT}/vendor/apple2tc-norom-src/lib/a2io/disk2.c"
readonly PIN_FILE="${REPO_ROOT}/vendor/apple2tc.COMMIT"
readonly LIB="${REPO_ROOT}/tools/lib"
readonly LICENSE_SOURCES=(
  "${REPO_ROOT}/vendor/apple2tc/LICENSE:apple2tc-LICENSE.txt"
  "${REPO_ROOT}/vendor/apple2tc/LICENSE_sokol:sokol-LICENSE.txt"
  "${REPO_ROOT}/vendor/apple2tc/external/json/LICENSE.MIT:nlohmann-json-LICENSE.txt"
)
readonly START_SUFFIXES=("" ".regs" ".lc" ".disk" ".blanked")
readonly MIN_MACOS="13.0"
readonly APP_VERSION="0.2.0"
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/55_wrap_t2.log"
SUMMARY_TITLE="Stage 5 T2-hybrid wrap"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"
# shellcheck source=lib/universal.sh
source "${REPO_ROOT}/tools/lib/universal.sh"

usage() {
  cat <<'EOF'
Usage: tools/55_wrap_t2.sh [--disk PATH] [--name "App Name"] [--dry-run] [--help]

Builds work/<disk-slug>/t2/<App Name>.app from tools/50_recompile.sh output
(which must have passed its equivalence and random-key gates).
An existing app of the same name is moved to <App Name>.app.backup-<time>.

  --disk PATH  default: the Number Munchers 4am crack .dsk in the repo
  --name NAME  App name (default: "<disk name> (T2-hybrid)")
  --dry-run    Check inputs and show what would be built; change nothing.
EOF
}

disk="${DEFAULT_DISK}"
app_name=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --disk) disk="${2:?--disk needs a path}"; shift 2 ;;
    --name) app_name="${2:?--name needs a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ -z "${app_name}" ]]; then app_name="$(basename "${disk}" | sed -E 's/\.[^.]+$//') (T2-hybrid)"; fi
if [[ "${app_name}" == */* || "${app_name}" == .* ]]; then
  echo "ERROR: --name must not contain '/' or start with '.'" >&2; exit 2
fi

slug="$(disk_slug "${disk}")"
readonly WORK_DIR="${REPO_ROOT}/work/${slug}"
readonly BUILD="${WORK_DIR}/t2build"
readonly ENGINE="${BUILD}/cmake/a2n-t2"
readonly START_IMAGE="${BUILD}/start/start"
readonly OUT_DIR="${WORK_DIR}/t2"
readonly APP_PATH="${OUT_DIR}/${app_name}.app"
readonly STAGING="${OUT_DIR}/.staging/${app_name}.app"
readonly BUNDLE_ID="org.apple2forge.t2.${slug}"

mkdir -p "${LOG_DIR}"
echo "=== 55_wrap_t2.sh $(date '+%Y-%m-%d %H:%M:%S %z') disk=${disk} name=${app_name}" >> "${LOG_FILE}"

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
for tool in codesign plutil python3 shasum; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${tool} (xcode-select --install)." 3
  fi
done
if [[ ! -r "${disk}" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "Cannot read disk image: ${disk}" 2
fi
for needed in "${LAUNCHER}" "${NOTICE}" "${ROM_FILE}" "${DISK2_SOURCE}" "${PIN_FILE}" "${ENGINE}"; do
  if [[ ! -r "${needed}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${needed#"${REPO_ROOT}"/}. Run tools/50_recompile.sh first." 2
  fi
done
if ! is_universal "${ENGINE}"; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "${ENGINE#"${REPO_ROOT}"/} is $(describe_archs "${ENGINE}") only, not universal. Rebuild: rm -rf ${BUILD#"${REPO_ROOT}"/}/cmake && tools/50_recompile.sh" 2
fi
for suffix in "${START_SUFFIXES[@]}"; do
  if [[ ! -r "${START_IMAGE}${suffix}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing start image ${START_IMAGE#"${REPO_ROOT}"/}${suffix}. Run tools/50_recompile.sh." 2
  fi
done
for entry in "${LICENSE_SOURCES[@]}"; do
  if [[ ! -r "${entry%%:*}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing license file ${entry%%:*}. Run tools/00_setup.sh." 2
  fi
done
echo "    disk: ${disk}"
echo "    app:  ${APP_PATH#"${REPO_ROOT}"/}"
pass_gate "Gate 0: Inputs" "${gate_start}"

# ── Gate 1: the recompile proved equivalence ────────────────────────
gate_start="$(date +%s)"
echo "[Gate 1] Recompile equivalence reports"
if ! native_share="$(python3 -I - "${BUILD}/equivalence/equivalence.json" "${BUILD}/fuzz/equivalence/equivalence.json" "${ENGINE}" <<'PY' 2>&1
import json, os, sys
engine_time = os.path.getmtime(sys.argv[3])
shares = []
for path in sys.argv[1:3]:
    if not os.path.exists(path):
        sys.exit(f"missing {path}: run tools/50_recompile.sh without --skip-equivalence")
    if os.path.getmtime(path) < engine_time:
        sys.exit(f"{path} is older than the engine: rerun tools/50_recompile.sh")
    total = json.load(open(path))["total"]
    if total["equivalent"] != total["sessions"]:
        sys.exit(f"{path}: {total['equivalent']}/{total['sessions']} sessions equivalent")
    shares.append(total["min_native_percent"])
print(min(shares))
PY
)"; then
  fail_gate "Gate 1: Equivalence reports" "${gate_start}" "${native_share}"
fi
echo "    every recorded and random-key session equivalent; lowest native share ${native_share}%"
pass_gate "Gate 1: Equivalence reports" "${gate_start}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[dry-run] would assemble, scan, sign and verify ${APP_PATH#"${REPO_ROOT}"/}"
  print_summary "PASSED (dry run)"
  exit 0
fi

# ── Gate 2: assemble bundle in staging ──────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 2] Assemble bundle"
rm -rf "${OUT_DIR}/.staging"
mkdir -p "${STAGING}/Contents/MacOS" "${STAGING}/Contents/Resources/licenses" "${STAGING}/Contents/Resources/start"
cp "${LAUNCHER}" "${STAGING}/Contents/MacOS/launcher"
cp "${ENGINE}" "${STAGING}/Contents/MacOS/a2n-t2"
chmod 0755 "${STAGING}/Contents/MacOS/launcher" "${STAGING}/Contents/MacOS/a2n-t2"
for suffix in "${START_SUFFIXES[@]}"; do
  cp "${START_IMAGE}${suffix}" "${STAGING}/Contents/Resources/start/start${suffix}"
done
cp "${disk}" "${STAGING}/Contents/Resources/disk.dsk"
chmod 0444 "${STAGING}/Contents/Resources/disk.dsk" "${STAGING}/Contents/Resources/start/"*
cp "${NOTICE}" "${STAGING}/Contents/Resources/NOTICE.txt"
for entry in "${LICENSE_SOURCES[@]}"; do
  cp "${entry%%:*}" "${STAGING}/Contents/Resources/licenses/${entry##*:}"
done

plist="${STAGING}/Contents/Info.plist"
plutil -create xml1 "${plist}"
plutil -insert CFBundleDevelopmentRegion -string "en" "${plist}"
plutil -insert CFBundleExecutable -string "launcher" "${plist}"
plutil -insert CFBundleIdentifier -string "${BUNDLE_ID}" "${plist}"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "${plist}"
plutil -insert CFBundleName -string "${app_name}" "${plist}"
plutil -insert CFBundleDisplayName -string "${app_name}" "${plist}"
plutil -insert CFBundlePackageType -string "APPL" "${plist}"
plutil -insert CFBundleShortVersionString -string "${APP_VERSION}" "${plist}"
plutil -insert CFBundleVersion -string "1" "${plist}"
plutil -insert LSMinimumSystemVersion -string "${MIN_MACOS}" "${plist}"
plutil -insert LSApplicationCategoryType -string "public.app-category.games" "${plist}"
plutil -insert NSHighResolutionCapable -bool true "${plist}"
plutil -insert NSHumanReadableCopyright -string "Personal-use build. Do not distribute; see NOTICE.txt." "${plist}"
plutil -insert A2NTier -string "T2-hybrid" "${plist}"
plutil -insert A2NEngine -string "a2n-t2: apple2tc $(cut -c1-12 "${PIN_FILE}") --run-data --simple-c + 6502 interpreter fallback" "${plist}"
plutil -insert A2NNativePercentMin -string "${native_share}" "${plist}"
plutil -insert A2NDiskSHA256 -string "$(sha256_of "${disk}")" "${plist}"
plutil -insert A2NRomPath -string "~/Library/Application Support/Apple2Forge/roms/apple2plus.rom (optional)" "${plist}"
if ! plutil -lint "${plist}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 2: Assemble bundle" "${gate_start}" "Info.plist failed plutil -lint; see log."
fi
pass_gate "Gate 2: Assemble bundle" "${gate_start}"

# ── Gate 3: no ROM / PROM bytes in what the build adds ──────────────
# The disk image is the user's own file, copied unchanged (checked by hash).
gate_start="$(date +%s)"
echo "[Gate 3] No Apple ROM or Disk II PROM bytes in the bundle"
scan_failed=0
while IFS= read -r -d '' file; do
  if [[ "${file}" == "${STAGING}/Contents/Resources/disk.dsk" ]]; then continue; fi
  if ! python3 -I "${LIB}/t2_romscan.py" "${file}" "${ROM_FILE}" "${DISK2_SOURCE}" >>"${LOG_FILE}" 2>&1; then
    echo "    ROM bytes in ${file#"${STAGING}"/}"
    scan_failed=1
  fi
done < <(find "${STAGING}" -type f -print0)
if [[ "$(sha256_of "${STAGING}/Contents/Resources/disk.dsk")" != "$(sha256_of "${disk}")" ]]; then
  echo "    disk.dsk differs from the supplied disk image"
  scan_failed=1
fi
if [[ "${scan_failed}" -ne 0 ]]; then
  fail_gate "Gate 3: No ROM in bundle" "${gate_start}" "See ${LOG_FILE#"${REPO_ROOT}"/}. Do not ship this build."
fi
pass_gate "Gate 3: No ROM in bundle" "${gate_start}"

# ── Gate 4: ad-hoc sign + strict verify ─────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 4] Sign (ad-hoc) and verify"
if ! codesign --force --sign - --timestamp=none "${STAGING}/Contents/MacOS/a2n-t2" >>"${LOG_FILE}" 2>&1 \
  || ! codesign --force --sign - --timestamp=none "${STAGING}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 4: Sign + verify" "${gate_start}" "codesign failed; see log."
fi
if ! codesign --verify --strict --deep --verbose=2 "${STAGING}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 4: Sign + verify" "${gate_start}" "codesign --verify --strict failed; see log."
fi
pass_gate "Gate 4: Sign + verify" "${gate_start}"

# ── Gate 5: install (back up previous build) ────────────────────────
gate_start="$(date +%s)"
echo "[Gate 5] Install to ${APP_PATH#"${REPO_ROOT}"/}"
if [[ -d "${APP_PATH}" ]]; then
  backup="${APP_PATH}.backup-$(date +%Y%m%d_%H%M%S)"
  mv "${APP_PATH}" "${backup}"
  echo "    previous build moved to ${backup#"${REPO_ROOT}"/}"
  ARTIFACTS+=("${backup#"${REPO_ROOT}"/}")
fi
mv "${STAGING}" "${APP_PATH}"
rm -rf "${OUT_DIR}/.staging"
if ! codesign --verify --strict --deep "${APP_PATH}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 5: Install" "${gate_start}" "Signature no longer verifies after the move."
fi
ARTIFACTS+=("${APP_PATH#"${REPO_ROOT}"/}")
pass_gate "Gate 5: Install" "${gate_start}"

print_artifacts
print_summary "PASSED"
