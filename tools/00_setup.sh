#!/bin/bash
set -euo pipefail

# Stage 0 — toolchain check, clone + build apple2tc / a2emu, pin commit.
# Exit codes: 0 success, 1 runtime failure, 2 config error, 3 missing dependency.

readonly APPLE2TC_URL="https://github.com/tmikov/apple2tc.git"
readonly HELP_TIMEOUT_SECONDS=10
readonly DIAG_TAIL_LINES=40
readonly PROGRESS_INTERVAL_SECONDS=5

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly VENDOR_DIR="${REPO_ROOT}/vendor/apple2tc"
readonly BUILD_DIR="${VENDOR_DIR}/build"
readonly COMMIT_FILE="${REPO_ROOT}/vendor/apple2tc.COMMIT"
readonly LOG_DIR="${REPO_ROOT}/work/_logs"
readonly LOG_FILE="${LOG_DIR}/00_setup.log"

DRY_RUN=0
UPDATE_PIN=0

GATE_NAMES=()
GATE_STATUS=()
GATE_SECONDS=()
ARTIFACTS=()
SCRIPT_START="$(date +%s)"

usage() {
  cat <<'EOF'
Usage: tools/00_setup.sh [--dry-run] [--update] [--help]

Stage 0 of apple2-native. Checks the macOS toolchain, clones and builds
tmikov/apple2tc (apple2tc + a2emu) into vendor/apple2tc/build, verifies both
binaries start, and records the pinned commit in vendor/apple2tc.COMMIT.

  --dry-run   Print what each gate would do; change nothing.
  --update    Move the pin to the latest upstream commit (default: honor the
              existing vendor/apple2tc.COMMIT if present).
  --help      Show this help.

Safe to re-run: clone is skipped if present, build is incremental.
Log: work/_logs/00_setup.log
EOF
}

for arg in "$@"; do
  case "${arg}" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --update) UPDATE_PIN=1 ;;
    *) echo "ERROR: unknown option '${arg}'" >&2; usage >&2; exit 2 ;;
  esac
done

print_summary() {
  local overall="$1"
  local total=$(( $(date +%s) - SCRIPT_START ))
  local i
  echo
  echo "══════════════════════════════════════════════════════════"
  echo "EXECUTION SUMMARY — Stage 0"
  echo "──────────────────────────────────────────────────────────"
  printf "%-40s %-8s %s\n" "Step" "Status" "Duration"
  echo "──────────────────────────────────────────────────────────"
  for i in "${!GATE_NAMES[@]}"; do
    printf "%-40s %-8s %ss\n" "${GATE_NAMES[$i]}" "${GATE_STATUS[$i]}" "${GATE_SECONDS[$i]}"
  done
  echo "──────────────────────────────────────────────────────────"
  echo "Overall: ${overall} | Total time: ${total}s"
  echo "══════════════════════════════════════════════════════════"
}

print_artifacts() {
  local item
  echo "Artifacts completed so far:"
  if [[ ${#ARTIFACTS[@]} -eq 0 ]]; then
    echo "  (none)"
  else
    for item in "${ARTIFACTS[@]}"; do echo "  - ${item}"; done
  fi
}

record_gate() {
  GATE_NAMES+=("$1")
  GATE_STATUS+=("$2")
  GATE_SECONDS+=("$3")
}

fail_gate() {
  local gate_name="$1"
  local started="$2"
  local repair="$3"
  local exit_code="${4:-1}"
  record_gate "${gate_name}" "FAILED" "$(( $(date +%s) - started ))"
  echo "  [FAILED] ${gate_name}" >&2
  echo >&2
  print_artifacts >&2
  echo >&2
  echo "Diagnostics (last ${DIAG_TAIL_LINES} log lines from ${LOG_FILE}):" >&2
  tail -n "${DIAG_TAIL_LINES}" "${LOG_FILE}" >&2 || true
  echo >&2
  echo "Repair:" >&2
  echo "${repair}" >&2
  print_summary "FAILED"
  exit "${exit_code}"
}

pass_gate() {
  local gate_name="$1"
  local started="$2"
  record_gate "${gate_name}" "PASSED" "$(( $(date +%s) - started ))"
  echo "  [PASSED] ${gate_name}"
}

log() {
  echo "$*" >> "${LOG_FILE}"
}

# Runs a long command in the background, printing elapsed time until it ends.
run_with_progress() {
  local label="$1"; shift
  local started pid status
  started="$(date +%s)"
  "$@" >> "${LOG_FILE}" 2>&1 &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    sleep "${PROGRESS_INTERVAL_SECONDS}"
    if kill -0 "${pid}" 2>/dev/null; then
      echo "    … ${label}: $(( $(date +%s) - started ))s elapsed"
    fi
  done
  status=0
  wait "${pid}" || status=$?
  return "${status}"
}

# Runs "<binary> --help" with a hard timeout; exit 142 means it hung.
run_help_with_timeout() {
  local binary="$1"
  perl -e 'alarm shift; exec { $ARGV[0] } @ARGV' "${HELP_TIMEOUT_SECONDS}" "${binary}" --help 2>&1
}

find_binary() {
  local name="$1"
  find "${BUILD_DIR}" -type f -name "${name}" -perm -u+x -not -path '*/CMakeFiles/*' 2>/dev/null | head -n 1 || true
}

mkdir -p "${LOG_DIR}"
{
  echo "=================================================="
  echo "00_setup.sh run $(date '+%Y-%m-%d %H:%M:%S %z') dry_run=${DRY_RUN} update=${UPDATE_PIN}"
} >> "${LOG_FILE}"

echo "Stage 0 — repo: ${REPO_ROOT}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "(dry run — no changes will be made)"
fi

# ── Gate 0: platform ────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Platform check"
os_name="$(uname -s)"
arch_name="$(uname -m)"
os_version="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
log "platform: ${os_name} ${arch_name} macOS ${os_version}"
echo "    macOS ${os_version} on ${arch_name}"
if [[ "${os_name}" != "Darwin" || "${arch_name}" != "arm64" ]]; then
  fail_gate "Gate 0: Platform (macOS arm64)" "${gate_start}" \
    "This project targets Apple Silicon macOS. Run it on an arm64 Mac (not under Rosetta: check 'uname -m')." 2
fi
pass_gate "Gate 0: Platform (macOS arm64)" "${gate_start}"

# ── Gate 1: required tools ──────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 1] Toolchain check"
missing_tools=()
for tool in git cmake clang++ swift python3 perl; do
  if tool_path="$(command -v "${tool}")"; then
    case "${tool}" in
      git)     tool_version="$(git --version)" ;;
      cmake)   tool_version="$(cmake --version | head -n 1)" ;;
      clang++) tool_version="$(clang++ --version | head -n 1)" ;;
      swift)   tool_version="$(swift --version 2>&1 | grep -m 1 'Swift version' || echo 'version unknown')" ;;
      python3) tool_version="$(python3 --version 2>&1)" ;;
      perl)    tool_version="perl $(perl -e 'print $^V')" ;;
    esac
    printf "    %-8s %s  (%s)\n" "${tool}" "${tool_version}" "${tool_path}"
    log "tool ${tool}: ${tool_path} — ${tool_version}"
  else
    missing_tools+=("${tool}")
    log "tool ${tool}: MISSING"
  fi
done
if [[ ${#missing_tools[@]} -gt 0 ]]; then
  fail_gate "Gate 1: Toolchain" "${gate_start}" \
    "Missing: ${missing_tools[*]}
  xcode-select --install        # git, clang++, swift, perl
  brew install cmake python3    # cmake, python3" 3
fi
pass_gate "Gate 1: Toolchain" "${gate_start}"

# ── Gate 2: clone / fetch apple2tc ──────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 2] apple2tc source"
pinned_commit=""
if [[ -f "${COMMIT_FILE}" && "${UPDATE_PIN}" -eq 0 ]]; then
  pinned_commit="$(tr -d '[:space:]' < "${COMMIT_FILE}")"
  echo "    honoring pin ${pinned_commit}"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  if [[ -d "${VENDOR_DIR}/.git" ]]; then
    echo "    would reuse existing clone at vendor/apple2tc"
  else
    echo "    would run: git clone ${APPLE2TC_URL} vendor/apple2tc"
  fi
  if [[ -n "${pinned_commit}" ]]; then
    echo "    would check out ${pinned_commit}"
  fi
  record_gate "Gate 2: Clone apple2tc" "DRY-RUN" 0
else
  if [[ -d "${VENDOR_DIR}/.git" ]]; then
    echo "    existing clone found"
    if [[ "${UPDATE_PIN}" -eq 1 ]] || { [[ -n "${pinned_commit}" ]] && ! git -C "${VENDOR_DIR}" cat-file -e "${pinned_commit}^{commit}" 2>/dev/null; }; then
      run_with_progress "git fetch" git -C "${VENDOR_DIR}" fetch --tags origin \
        || fail_gate "Gate 2: Clone apple2tc" "${gate_start}" \
          "Check network access to github.com, then: git -C vendor/apple2tc fetch origin"
    fi
    if [[ "${UPDATE_PIN}" -eq 1 ]]; then
      default_ref="$(git -C "${VENDOR_DIR}" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/master)"
      git -C "${VENDOR_DIR}" checkout -q --detach "${default_ref}" >> "${LOG_FILE}" 2>&1 \
        || fail_gate "Gate 2: Clone apple2tc" "${gate_start}" \
          "Could not check out ${default_ref}. Inspect: git -C vendor/apple2tc status"
    fi
  else
    if [[ -e "${VENDOR_DIR}" ]]; then
      fail_gate "Gate 2: Clone apple2tc" "${gate_start}" \
        "vendor/apple2tc exists but is not a git clone. Move it aside:
  mv vendor/apple2tc vendor/apple2tc.backup-\$(date +%Y%m%d_%H%M%S)" 2
    fi
    run_with_progress "git clone" git clone "${APPLE2TC_URL}" "${VENDOR_DIR}" \
      || fail_gate "Gate 2: Clone apple2tc" "${gate_start}" \
        "Check network access to github.com, then re-run this script."
  fi
  if [[ -n "${pinned_commit}" ]]; then
    git -C "${VENDOR_DIR}" checkout -q --detach "${pinned_commit}" >> "${LOG_FILE}" 2>&1 \
      || fail_gate "Gate 2: Clone apple2tc" "${gate_start}" \
        "Pinned commit ${pinned_commit} not found upstream. Re-pin with: tools/00_setup.sh --update"
  fi
  if [[ ! -f "${VENDOR_DIR}/CMakeLists.txt" ]]; then
    fail_gate "Gate 2: Clone apple2tc" "${gate_start}" \
      "Clone has no CMakeLists.txt. Remove and re-run: rm -rf vendor/apple2tc && tools/00_setup.sh"
  fi
  ARTIFACTS+=("vendor/apple2tc (source clone)")
  pass_gate "Gate 2: Clone apple2tc" "${gate_start}"
fi

# ── Gate 3: CMake configure ─────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 3] CMake configure"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "    would run: cmake -S vendor/apple2tc -B vendor/apple2tc/build -DCMAKE_BUILD_TYPE=Release"
  record_gate "Gate 3: CMake configure" "DRY-RUN" 0
else
  run_with_progress "cmake configure" cmake -S "${VENDOR_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release \
    || fail_gate "Gate 3: CMake configure" "${gate_start}" \
      "Configure failed (see diagnostics). Common fix — clear the cache and retry:
  rm -rf vendor/apple2tc/build && tools/00_setup.sh"
  ARTIFACTS+=("vendor/apple2tc/build (CMake cache)")
  pass_gate "Gate 3: CMake configure" "${gate_start}"
fi

# ── Gate 4: build ───────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 4] Build (this can take a few minutes)"
cpu_count="$(sysctl -n hw.ncpu)"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "    would run: cmake --build vendor/apple2tc/build -j${cpu_count}"
  record_gate "Gate 4: Build" "DRY-RUN" 0
else
  run_with_progress "build" cmake --build "${BUILD_DIR}" -j "${cpu_count}" \
    || fail_gate "Gate 4: Build" "${gate_start}" \
      "Compile failed (see diagnostics). Upstream may not support this compiler/CMake.
  Try a clean build:      rm -rf vendor/apple2tc/build && tools/00_setup.sh
  Do NOT patch upstream source without recording it in docs/CHANGES.md."
  ARTIFACTS+=("vendor/apple2tc/build (compiled targets)")
  pass_gate "Gate 4: Build" "${gate_start}"
fi

# ── Gate 5: binaries start ──────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 5] Binaries run"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "    would locate a2emu and apple2tc under vendor/apple2tc/build and run each with --help"
  record_gate "Gate 5: Binaries run (--help)" "DRY-RUN" 0
else
  for binary_name in apple2tc a2emu; do
    binary_path="$(find_binary "${binary_name}")"
    if [[ -z "${binary_path}" ]]; then
      log "binary ${binary_name}: not found under ${BUILD_DIR}"
      log "executables present: $(find "${BUILD_DIR}" -type f -perm -u+x -not -path '*/CMakeFiles/*' | sed "s|${BUILD_DIR}/||" | tr '\n' ' ')"
      fail_gate "Gate 5: Binaries run (--help)" "${gate_start}" \
        "'${binary_name}' was not built. List built targets with:
  cmake --build vendor/apple2tc/build --target help"
    fi
    help_status=0
    help_output="$(run_help_with_timeout "${binary_path}")" || help_status=$?
    log "--- ${binary_name} --help (exit ${help_status}) ---"
    log "${help_output}"
    relative_path="${binary_path#"${REPO_ROOT}"/}"
    if [[ "${help_status}" -eq 142 ]]; then
      fail_gate "Gate 5: Binaries run (--help)" "${gate_start}" \
        "${binary_name} did not exit within ${HELP_TIMEOUT_SECONDS}s on --help (may be waiting for a window/display)."
    fi
    if [[ -z "${help_output}" ]]; then
      fail_gate "Gate 5: Binaries run (--help)" "${gate_start}" \
        "${binary_name} --help printed nothing (exit ${help_status}). Run it by hand: ${relative_path} --help"
    fi
    echo "    ${binary_name}: ${relative_path} — exit ${help_status}, first line: $(echo "${help_output}" | head -n 1)"
    ARTIFACTS+=("${relative_path}")
  done
  pass_gate "Gate 5: Binaries run (--help)" "${gate_start}"
fi

# ── Gate 6: record pinned commit ────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 6] Record pinned commit"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "    would write HEAD of vendor/apple2tc to vendor/apple2tc.COMMIT"
  record_gate "Gate 6: Pin commit" "DRY-RUN" 0
else
  head_commit="$(git -C "${VENDOR_DIR}" rev-parse HEAD)"
  commit_tmp="${COMMIT_FILE}.tmp"
  echo "${head_commit}" > "${commit_tmp}"
  mv "${commit_tmp}" "${COMMIT_FILE}"
  written_commit="$(tr -d '[:space:]' < "${COMMIT_FILE}")"
  if [[ ! "${written_commit}" =~ ^[0-9a-f]{40}$ || "${written_commit}" != "${head_commit}" ]]; then
    fail_gate "Gate 6: Pin commit" "${gate_start}" \
      "Commit file is invalid. Check: git -C vendor/apple2tc rev-parse HEAD"
  fi
  commit_subject="$(git -C "${VENDOR_DIR}" log -1 --format='%cs %s' HEAD)"
  echo "    ${head_commit} (${commit_subject})"
  log "pinned ${head_commit} (${commit_subject})"
  ARTIFACTS+=("vendor/apple2tc.COMMIT")
  pass_gate "Gate 6: Pin commit" "${gate_start}"
fi

echo
print_artifacts
if [[ "${DRY_RUN}" -eq 1 ]]; then
  print_summary "DRY-RUN"
else
  print_summary "PASSED"
fi
exit 0
