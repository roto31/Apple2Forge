#!/bin/bash
set -euo pipefail

# Stage 2: build a T1 ("Wrap") macOS app for one or more disk images (all sides).
# The app holds a launcher script, the ROM-free + Language Card a2emu, bundled
# disks, the personal-use notice and third-party licenses. It reads the
# operator's ROM from ~/Library/Application Support at launch. Ad-hoc signed.
# Output: work/<disk-slug>/t1/<Name>.app
# Exit codes: 0 success, 1 gate failed, 2 config error, 3 missing dependency.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly EMULATOR="${REPO_ROOT}/build/a2emu-norom/a2emu"
readonly EMULATOR_INFO="${REPO_ROOT}/build/a2emu-norom/BUILD_INFO.txt"
readonly LAUNCHER="${REPO_ROOT}/tools/t1/launcher.sh"
readonly NOTICE="${REPO_ROOT}/tools/t1/NOTICE.txt"
readonly ROM_FILE="${REPO_ROOT}/roms/apple2plus.rom"
readonly PIN_FILE="${REPO_ROOT}/vendor/apple2tc.COMMIT"
readonly DISK_SET_TOOL="${REPO_ROOT}/tools/lib/t1_disk_set.py"
readonly MACHINE_TOOL="${REPO_ROOT}/tools/lib/t1_machine.py"
readonly DEFAULT_ROM_DIR="${HOME}/Library/Application Support/Apple2Forge/roms"
readonly LICENSE_SOURCES=(
  "${REPO_ROOT}/vendor/apple2tc/LICENSE:apple2tc-LICENSE.txt"
  "${REPO_ROOT}/vendor/apple2tc/LICENSE_sokol:sokol-LICENSE.txt"
  "${REPO_ROOT}/vendor/apple2tc/external/json/LICENSE.MIT:nlohmann-json-LICENSE.txt"
)
readonly SUPPORTED_DISK_BYTES=143360
readonly MIN_MACOS="13.0"
readonly APP_VERSION="0.1.0"
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
LOG_FILE="${LOG_DIR}/20_wrap_t1.log"
SUMMARY_TITLE="Stage 2 T1 wrap"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<'EOF'
Usage: tools/20_wrap_t1.sh DISK_IMAGE [DISK2 ...] [--name "App Name"] [--model auto|iiplus|iie]
       [--rom-dir DIR] [--dry-run] [--help]

Builds work/<disk-slug>/t1/<App Name>.app: a T1 (emulator wrap) app that
boots the first side and bundles every listed disk/side. Needs
tools/15_build_a2emu_norom.sh to have run. Runs the Stage 1 analyzer on the
boot side if work/<disk-slug>/analysis.json is missing.
An existing app of the same name is moved to <App Name>.app.backup-<time>.

  --name NAME     App name (default: parsed title or first disk base name)
  --model M       iiplus, iie, or auto (default: auto — headless boot test)
  --rom-dir DIR   ROM folder for machine auto-select (default: ~/Library/.../roms)
  --dry-run       Show what would be built; change nothing.
EOF
}

disks=()
app_name=""
MODEL="auto"
rom_dir="${DEFAULT_ROM_DIR}"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --name) app_name="${2:?--name needs a value}"; shift 2 ;;
    --model=*) MODEL="${1#*=}"; shift ;;
    --model) MODEL="${2:?--model needs a value}"; shift 2 ;;
    --rom-dir=*) rom_dir="${1#*=}"; shift ;;
    --rom-dir) rom_dir="${2:?--rom-dir needs a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) disks+=("$1"); shift ;;
  esac
done
if [[ ${#disks[@]} -eq 0 ]]; then usage >&2; exit 2; fi
case "${MODEL}" in auto|iiplus|iie) ;; *) echo "ERROR: --model must be auto, iiplus, or iie" >&2; exit 2 ;; esac

disk_set_json=""
if ! disk_set_json="$(python3 -I "${DISK_SET_TOOL}" "${disks[@]}")"; then
  echo "ERROR: could not order disk images (overlapping disk/side labels?)" >&2
  exit 2
fi
disk="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["bootPath"])' <<<"${disk_set_json}")"
parsed_title="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["title"])' <<<"${disk_set_json}")"
if [[ -z "${app_name}" ]]; then app_name="${parsed_title}"; fi
if [[ "${app_name}" == */* || "${app_name}" == .* ]]; then
  echo "ERROR: --name must not contain '/' or start with '.'" >&2; exit 2
fi

slug="$(disk_slug "${disk}")"
readonly WORK_DIR="${REPO_ROOT}/work/${slug}"
readonly ANALYSIS="${WORK_DIR}/analysis.json"
readonly OUT_DIR="${WORK_DIR}/t1"
readonly APP_PATH="${OUT_DIR}/${app_name}.app"
readonly STAGING="${OUT_DIR}/.staging/${app_name}.app"
readonly BUNDLE_ID="org.apple2forge.t1.${slug}"

mkdir -p "${LOG_DIR}"
echo "=== 20_wrap_t1.sh $(date '+%Y-%m-%d %H:%M:%S %z') disks=${#disks[@]} name=${app_name}" >> "${LOG_FILE}"

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
for tool in codesign plutil python3 shasum ditto; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${tool} (xcode-select --install)." 3
  fi
done
for d in "${disks[@]}"; do
  if [[ ! -r "${d}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Cannot read disk image: ${d}" 2
  fi
done
for needed in "${EMULATOR}" "${EMULATOR_INFO}" "${LAUNCHER}" "${NOTICE}" "${ROM_FILE}" "${PIN_FILE}" \
  "${DISK_SET_TOOL}" "${MACHINE_TOOL}"; do
  if [[ ! -r "${needed}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${needed#"${REPO_ROOT}"/}. Emulator: tools/15_build_a2emu_norom.sh; ROM: tools/05_fetch_rom.sh." 2
  fi
done
if ! grep -q "a2emu-language-card.patch" "${EMULATOR_INFO}"; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "build/a2emu-norom/a2emu predates the Language Card patch. Rebuild: tools/15_build_a2emu_norom.sh" 2
fi
if ! grep -q "a2emu-disk-menu.patch" "${EMULATOR_INFO}"; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "build/a2emu-norom/a2emu predates the T1 disk menu. Rebuild: tools/15_build_a2emu_norom.sh" 2
fi
for entry in "${LICENSE_SOURCES[@]}"; do
  if [[ ! -r "${entry%%:*}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing license file ${entry%%:*}. Run tools/00_setup.sh." 2
  fi
done
echo "    boot: ${disk}"
echo "    sides: ${#disks[@]}"
echo "    app:  ${APP_PATH#"${REPO_ROOT}"/}"
pass_gate "Gate 0: Inputs" "${gate_start}"

# ── Gate 1: analysis says the boot side is supported ────────────────
gate_start="$(date +%s)"
echo "[Gate 1] Stage 1 analysis"
if [[ ! -f "${ANALYSIS}" ]]; then
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "    would run: tools/10_analyze.sh (analysis.json missing)"
  elif ! "${REPO_ROOT}/tools/10_analyze.sh" "${disk}" >>"${LOG_FILE}" 2>&1; then
    fail_gate "Gate 1: Analysis" "${gate_start}" "tools/10_analyze.sh failed; run it by hand to see why."
  fi
fi
if [[ -f "${ANALYSIS}" ]]; then
  supported="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["summary"]["supported"])' "${ANALYSIS}")"
  if [[ "${supported}" != "True" ]]; then
    fail_gate "Gate 1: Analysis" "${gate_start}" "Stage 1 marks this disk unsupported; see ${WORK_DIR#"${REPO_ROOT}"/}/analysis.md." 2
  fi
fi
while IFS= read -r side_path; do
  if [[ "$(/usr/bin/stat -f %z "${side_path}")" -ne "${SUPPORTED_DISK_BYTES}" ]]; then
    fail_gate "Gate 1: Analysis" "${gate_start}" "${side_path} is not a 140K sector image." 2
  fi
done < <(python3 -I -c 'import json,sys; [print(s["path"]) for s in json.load(sys.stdin)["sides"]]' <<<"${disk_set_json}")
pass_gate "Gate 1: Analysis" "${gate_start}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[dry-run] disk set:"
  python3 -I -c 'import json,sys; [print(f"  {s[\"label\"]} -> {s[\"bundleFile\"]}") for s in json.load(sys.stdin)["sides"]]' <<<"${disk_set_json}"
  echo "[dry-run] would run Gate 1b machine (${MODEL}) and assemble ${APP_PATH#"${REPO_ROOT}"/}"
  print_summary "PASSED (dry run)"
  exit 0
fi

# ── Gate 1b: machine (II+ vs //e) ───────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 1b] Machine (${MODEL})"
machine_json=""
machine_args=(--emulator "${EMULATOR}" --rom-dir "${rom_dir}" --model "${MODEL}")
while IFS= read -r side_path; do machine_args+=("${side_path}"); done \
  < <(python3 -I -c 'import json,sys; d=json.load(sys.stdin)["sides"]; print(d[0]["path"]); print(d[1]["path"] if len(d)>1 else "")' <<<"${disk_set_json}" | sed '/^$/d')
if ! machine_json="$(python3 -I "${MACHINE_TOOL}" "${machine_args[@]}")"; then
  fail_gate "Gate 1b: Machine" "${gate_start}" "Could not choose Apple II model; see log and install ROMs in ${rom_dir}." 2
fi
A2N_MACHINE="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["machine"])' <<<"${machine_json}")"
A2N_MACHINE_REASON="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["detail"])' <<<"${machine_json}")"
echo "    machine: ${A2N_MACHINE} (${A2N_MACHINE_REASON})"
pass_gate "Gate 1b: Machine" "${gate_start}"

# ── Gate 2: assemble bundle in staging ──────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 2] Assemble bundle"
rm -rf "${OUT_DIR}/.staging"
mkdir -p "${STAGING}/Contents/MacOS" "${STAGING}/Contents/Resources/licenses"
cp "${LAUNCHER}" "${STAGING}/Contents/MacOS/launcher"
cp "${EMULATOR}" "${STAGING}/Contents/MacOS/a2emu"
chmod 0755 "${STAGING}/Contents/MacOS/launcher" "${STAGING}/Contents/MacOS/a2emu"
python3 -I - "${disk_set_json}" "${STAGING}/Contents/Resources" <<'PY'
import json, os, shutil, sys
data = json.loads(sys.argv[1])
resources = sys.argv[2]
tsv = os.path.join(resources, "disks.tsv")
with open(tsv, "w", encoding="utf-8") as handle:
    for side in data["sides"]:
        dest = os.path.join(resources, side["bundleFile"])
        shutil.copy2(side["path"], dest)
        os.chmod(dest, 0o444)
        handle.write(f"{side['startupDrive']}\t{side['label']}\t{side['bundleFile']}\n")
PY
cp "${NOTICE}" "${STAGING}/Contents/Resources/NOTICE.txt"
for entry in "${LICENSE_SOURCES[@]}"; do
  cp "${entry%%:*}" "${STAGING}/Contents/Resources/licenses/${entry##*:}"
done

disk_sha="$(sha256_of "${disk}")"
analysis_sha="$(sha256_of "${ANALYSIS}")"
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
plutil -insert A2NTier -string "T1" "${plist}"
engine_note="a2emu (apple2tc $(cut -c1-12 "${PIN_FILE}")) + Apple2Forge patches: require-rom, language-card, disk-menu"
if [[ "${A2N_MACHINE}" == "iie" ]]; then engine_note+=", iie"; fi
plutil -insert A2NEngine -string "${engine_note}" "${plist}"
plutil -insert A2NDiskSHA256 -string "${disk_sha}" "${plist}"
plutil -insert A2NAnalysisSHA256 -string "${analysis_sha}" "${plist}"
plutil -insert A2NMachine -string "${A2N_MACHINE}" "${plist}"
plutil -insert A2NMachineReason -string "${A2N_MACHINE_REASON}" "${plist}"
if [[ "${A2N_MACHINE}" == "iie" ]]; then
  plutil -insert A2NRomPaths -json '["~/Library/Application Support/Apple2Forge/roms/apple2e-enhanced.rom","~/Library/Application Support/Apple2Forge/roms/apple2e-video.rom"]' "${plist}"
else
  plutil -insert A2NRomPath -string "~/Library/Application Support/Apple2Forge/roms/apple2plus.rom" "${plist}"
fi
python3 -I - "${plist}" "${disk_set_json}" <<'PY'
import json, plistlib, sys
with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
info["A2NDiskSet"] = [
    {"label": s["label"], "file": s["bundleFile"], "sha256": s["sha256"]}
    for s in json.loads(sys.argv[2])["sides"]
]
with open(sys.argv[1], "wb") as handle:
    plistlib.dump(info, handle)
PY
if ! plutil -lint "${plist}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 2: Assemble bundle" "${gate_start}" "Info.plist failed plutil -lint; see log."
fi
pass_gate "Gate 2: Assemble bundle" "${gate_start}"

# ── Gate 3: no ROM bytes anywhere in the bundle ─────────────────────
gate_start="$(date +%s)"
echo "[Gate 3] No ROM bytes in the bundle"
rom_scan=( "${ROM_FILE}" )
for extra in "${rom_dir}/apple2e-enhanced.rom" "${rom_dir}/apple2e-video.rom"; do
  [[ -r "${extra}" ]] && rom_scan+=( "${extra}" )
done
if ! python3 -I - "${STAGING}" "${rom_scan[@]}" <<'PY' >>"${LOG_FILE}" 2>&1
import os, sys
WINDOW = 256
roms = []
for path in sys.argv[2:]:
    data = open(path, "rb").read()
    # A window of one repeated byte (the //e ROM's zero-filled I/O page) holds no
    # ROM content and would match any padded file, so it is not searched for.
    windows = [data[off:off + WINDOW] for off in range(0, len(data), WINDOW)]
    roms.append((path, [w for w in windows if len(set(w)) > 1]))
hits = []
for folder, _, files in os.walk(sys.argv[1]):
    for name in files:
        path = os.path.join(folder, name)
        data = open(path, "rb").read()
        for rom_path, windows in roms:
            found = sum(w in data for w in windows)
            if found:
                hits.append(f"{path}: {rom_path} {found}/{len(windows)}")
print("ROM windows found:", hits or "none")
sys.exit(1 if hits else 0)
PY
then
  fail_gate "Gate 3: No ROM in bundle" "${gate_start}" "ROM content found in the bundle (see log). Do not ship this build."
fi
pass_gate "Gate 3: No ROM in bundle" "${gate_start}"

# ── Gate 4: ad-hoc sign + strict verify ─────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 4] Sign (ad-hoc) and verify"
if ! codesign --force --sign - --timestamp=none "${STAGING}/Contents/MacOS/a2emu" >>"${LOG_FILE}" 2>&1 \
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
