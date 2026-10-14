#!/bin/bash
set -euo pipefail

# Stage 6 release signing: re-sign build/release/Apple2Forge.app (from
# tools/60_build_app.sh --release) with a Developer ID Application identity and
# the hardened runtime, notarize it with an App Store Connect API key, staple
# the ticket, check Gatekeeper accepts it, and zip it for a GitHub release.
# Credentials come from a gitignored env file and are never printed.
# Exit codes: 0 success, 1 gate failed, 2 config error, 3 missing dependency.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly RELEASE_DIR="${REPO_ROOT}/build/release"
readonly APP="${RELEASE_DIR}/Apple2Forge.app"
readonly BUILD_SCRIPT="${REPO_ROOT}/tools/60_build_app.sh"
readonly NESTED_EXECUTABLES=("Contents/Resources/a2emu")
readonly REQUIRED_ENV=(SIGN_IDENTITY ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH NOTARY_TEAM_ID)
readonly NOTARY_TIMEOUT="30m"
LOG_DIR="${REPO_ROOT}/work/_gate/stage6"
LOG_FILE="${LOG_DIR}/sign_notarize.log"
SUMMARY_TITLE="Stage 6 Apple2Forge.app sign + notarize"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"
# shellcheck source=lib/universal.sh
source "${REPO_ROOT}/tools/lib/universal.sh"

usage() {
  cat <<'EOF'
Usage: tools/65_sign_notarize.sh [--env-file PATH] [--skip-notarize] [--dry-run] [--help]

Signs build/release/Apple2Forge.app with Developer ID + hardened runtime,
notarizes and staples it, and writes build/release/Apple2Forge-<version>-macOS.zip
and .zip.sha256. Run tools/60_build_app.sh --release first.

  --env-file PATH  Signing settings (default: config/release.local.env, gitignored):
                     SIGN_IDENTITY   SHA-1 of the Developer ID Application identity
                     ASC_KEY_ID      App Store Connect API key ID (AuthKey_<ID>.p8)
                     ASC_ISSUER_ID   App Store Connect issuer UUID
                     ASC_KEY_PATH    path to AuthKey_<ID>.p8
                     NOTARY_TEAM_ID  Apple developer team ID
  --skip-notarize  Sign and verify only (the zip is not notarized; do not publish it).
  --dry-run        Check inputs only.
  --help           This text.
EOF
}

ENV_FILE="${REPO_ROOT}/config/release.local.env"
SKIP_NOTARIZE=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    --env-file=*) ENV_FILE="${1#*=}"; shift ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "${LOG_DIR}"
: > "${LOG_FILE}"

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
for tool in codesign xcrun ditto spctl lipo shasum plutil openssl python3 security; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "Missing ${tool}. Install Xcode or the command-line tools." 3
  fi
done
if [[ ! -f "${ENV_FILE}" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "No ${ENV_FILE}. Create it (mode 0600) with: ${REQUIRED_ENV[*]}." 2
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"
for name in "${REQUIRED_ENV[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "${name} is empty in ${ENV_FILE}." 2
  fi
done
key_path="${ASC_KEY_PATH/#\~/${HOME}}"
if [[ "$(basename "${key_path}")" != "AuthKey_${ASC_KEY_ID}.p8" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "ASC_KEY_PATH must be AuthKey_${ASC_KEY_ID}.p8 to match ASC_KEY_ID." 2
fi
if ! openssl pkey -in "${key_path}" -noout >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "ASC_KEY_PATH is missing or not a private key." 2
fi
if ! security find-identity -v -p codesigning | grep -F "${SIGN_IDENTITY}" | grep -q "Developer ID Application"; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "SIGN_IDENTITY is not a valid Developer ID Application identity in the keychain (security find-identity -v -p codesigning)." 2
fi
if [[ ! -d "${APP}" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "No ${APP#"${REPO_ROOT}"/}. Run tools/60_build_app.sh --release first." 2
fi
expected_version="$(sed -n 's/^readonly APP_VERSION="\(.*\)"$/\1/p' "${BUILD_SCRIPT}")"
app_version="$(plutil -extract CFBundleShortVersionString raw "${APP}/Contents/Info.plist")"
if [[ -z "${expected_version}" || "${app_version}" != "${expected_version}" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "App is version ${app_version}; tools/60_build_app.sh says ${expected_version}. Rebuild with --release." 2
fi
for executable in "Contents/MacOS/Apple2Forge" "${NESTED_EXECUTABLES[@]}"; do
  if ! is_universal "${APP}/${executable}"; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "${executable} is not universal. Rebuild: tools/60_build_app.sh --release" 2
  fi
done
readonly ZIP="${RELEASE_DIR}/Apple2Forge-${app_version}-macOS.zip"
echo "    version ${app_version}; output ${ZIP#"${REPO_ROOT}"/}"
pass_gate "Gate 0: Inputs" "${gate_start}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[dry-run] would sign, notarize, staple and zip ${APP#"${REPO_ROOT}"/}"
  print_summary "PASSED (dry run)"
  exit 0
fi

# ── Gate 1: Developer ID signature, hardened runtime ────────────────
# Nested code first; signing the bundle seals their signatures in.
gate_start="$(date +%s)"
echo "[Gate 1] Developer ID sign (hardened runtime, secure timestamp)"
for executable in "${NESTED_EXECUTABLES[@]}"; do
  if ! codesign --force --timestamp --options runtime --sign "${SIGN_IDENTITY}" "${APP}/${executable}" >>"${LOG_FILE}" 2>&1; then
    fail_gate "Gate 1: Sign" "${gate_start}" "codesign ${executable} failed; see ${LOG_FILE}."
  fi
done
if ! codesign --force --timestamp --options runtime --sign "${SIGN_IDENTITY}" "${APP}" >>"${LOG_FILE}" 2>&1 \
  || ! codesign --verify --strict --deep --verbose=2 "${APP}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 1: Sign" "${gate_start}" "codesign or verify failed; see ${LOG_FILE}."
fi
for target in "${APP}" "${APP}/${NESTED_EXECUTABLES[0]}"; do
  details="$(codesign -dvv "${target}" 2>&1)"
  if [[ "${details}" != *"Authority=Developer ID Application"* || "${details}" != *"(runtime)"* \
     || "${details}" != *"Timestamp="* || "${details}" != *"TeamIdentifier=${NOTARY_TEAM_ID}"* ]]; then
    echo "${details}" >> "${LOG_FILE}"
    fail_gate "Gate 1: Sign" "${gate_start}" "${target#"${APP}"/} lacks Developer ID authority, hardened runtime, timestamp or team ${NOTARY_TEAM_ID}; see ${LOG_FILE}."
  fi
done
pass_gate "Gate 1: Sign" "${gate_start}"

# ── Gate 2: notarize ────────────────────────────────────────────────
gate_start="$(date +%s)"
if [[ "${SKIP_NOTARIZE}" -eq 1 ]]; then
  skip_gate "Gate 2: Notarize" "--skip-notarize"
  skip_gate "Gate 3: Staple" "--skip-notarize"
else
  echo "[Gate 2] Notarize (waits up to ${NOTARY_TIMEOUT})"
  submit_zip="${RELEASE_DIR}/.notary-submit.zip"
  rm -f "${submit_zip}"
  if ! ditto -c -k --sequesterRsrc --keepParent "${APP}" "${submit_zip}" >>"${LOG_FILE}" 2>&1; then
    fail_gate "Gate 2: Notarize" "${gate_start}" "ditto could not zip the app; see ${LOG_FILE}."
  fi
  notary_json="${LOG_DIR}/notary-submit.json"
  notary_status=0
  xcrun notarytool submit "${submit_zip}" --key "${key_path}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}" \
    --wait --timeout "${NOTARY_TIMEOUT}" --output-format json > "${notary_json}" 2>>"${LOG_FILE}" || notary_status=$?
  rm -f "${submit_zip}"
  submission_id="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "${notary_json}" 2>/dev/null || true)"
  submission_status="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "${notary_json}" 2>/dev/null || true)"
  echo "    submission ${submission_id:-none}: ${submission_status:-no status}"
  if [[ -n "${submission_id}" ]]; then
    xcrun notarytool log "${submission_id}" --key "${key_path}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}" \
      "${LOG_DIR}/notary-log.json" >>"${LOG_FILE}" 2>&1 || true
  fi
  if [[ "${notary_status}" -ne 0 || "${submission_status}" != "Accepted" ]]; then
    fail_gate "Gate 2: Notarize" "${gate_start}" "Notarization was not accepted (exit ${notary_status}). Apple's report: ${LOG_DIR#"${REPO_ROOT}"/}/notary-log.json"
  fi
  ARTIFACTS+=("notarization ${submission_id}")
  pass_gate "Gate 2: Notarize" "${gate_start}"

  # ── Gate 3: staple ────────────────────────────────────────────────
  gate_start="$(date +%s)"
  echo "[Gate 3] Staple the ticket"
  if ! xcrun stapler staple "${APP}" >>"${LOG_FILE}" 2>&1 || ! xcrun stapler validate "${APP}" >>"${LOG_FILE}" 2>&1; then
    fail_gate "Gate 3: Staple" "${gate_start}" "stapler failed; see ${LOG_FILE}. Retry: xcrun stapler staple \"${APP}\""
  fi
  pass_gate "Gate 3: Staple" "${gate_start}"
fi

# ── Gate 4: Gatekeeper ──────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 4] Gatekeeper assessment"
assessment="$(spctl --assess --type execute --verbose=4 "${APP}" 2>&1 || true)"
echo "${assessment}" >> "${LOG_FILE}"
echo "    $(echo "${assessment}" | grep 'source=' || echo 'no source line')"
if [[ "${SKIP_NOTARIZE}" -eq 1 ]]; then
  skip_gate "Gate 4: Gatekeeper" "not notarized"
elif [[ "${assessment}" != *"accepted"* || "${assessment}" != *"source=Notarized Developer ID"* ]]; then
  fail_gate "Gate 4: Gatekeeper" "${gate_start}" "spctl did not accept the app as Notarized Developer ID; see ${LOG_FILE}."
else
  pass_gate "Gate 4: Gatekeeper" "${gate_start}"
fi

# ── Gate 5: release zip ─────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 5] Release zip"
if [[ -f "${ZIP}" ]]; then
  mv "${ZIP}" "${ZIP}.backup-$(date +%Y%m%d_%H%M%S)"
  rm -f "${ZIP}.sha256"
fi
if ! ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}" >>"${LOG_FILE}" 2>&1; then
  fail_gate "Gate 5: Release zip" "${gate_start}" "ditto failed; see ${LOG_FILE}."
fi
check_dir="$(mktemp -d)"
if ! ditto -x -k "${ZIP}" "${check_dir}" >>"${LOG_FILE}" 2>&1 \
  || ! codesign --verify --strict --deep "${check_dir}/Apple2Forge.app" >>"${LOG_FILE}" 2>&1; then
  rm -rf "${check_dir}"
  fail_gate "Gate 5: Release zip" "${gate_start}" "The unzipped app does not verify; see ${LOG_FILE}."
fi
if [[ "${SKIP_NOTARIZE}" -eq 0 ]] && ! xcrun stapler validate "${check_dir}/Apple2Forge.app" >>"${LOG_FILE}" 2>&1; then
  rm -rf "${check_dir}"
  fail_gate "Gate 5: Release zip" "${gate_start}" "The unzipped app lost its stapled ticket; see ${LOG_FILE}."
fi
rm -rf "${check_dir}"
(cd "${RELEASE_DIR}" && shasum -a 256 "$(basename "${ZIP}")" > "$(basename "${ZIP}").sha256")
echo "    $(cat "${ZIP}.sha256")"
ARTIFACTS+=("${ZIP#"${REPO_ROOT}"/}" "${ZIP#"${REPO_ROOT}"/}.sha256")
pass_gate "Gate 5: Release zip" "${gate_start}"

print_artifacts
print_summary "PASSED"
