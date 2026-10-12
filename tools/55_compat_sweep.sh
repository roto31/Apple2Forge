#!/bin/bash
set -euo pipefail

# Stage 6a: compatibility sweep. Boots every library title headless on the
# Apple II+ and, when that fails or the name points at a //e, on the Apple //e;
# writes LIBRARY/compat.json (which machine each title needs and why) and
# rebuilds the catalog so the app launches each title on the right machine.
# Exit codes: 0 success, 1 gate failed, 2 config error, 3 missing dependency.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SWEEP_TOOL="${REPO_ROOT}/tools/lib/compat_sweep.py"
readonly CATALOG_SCRIPT="${REPO_ROOT}/tools/50_library.sh"
readonly DEFAULT_LIBRARY="${HOME}/Library/Application Support/Apple2Forge/library"
readonly DEFAULT_EMULATOR="${REPO_ROOT}/build/a2emu-norom/a2emu"
readonly DEFAULT_ROM_DIR="${REPO_ROOT}/roms"
readonly REQUIRED_ROMS=(apple2plus.rom apple2e-enhanced.rom apple2e-video.rom)
readonly LOG_DIR="${HOME}/Library/Logs/Apple2Forge"
LOG_FILE="${LOG_DIR}/compat-sweep.log"
SUMMARY_TITLE="Stage 6a compatibility sweep"
# shellcheck source=lib/gates.sh
source "${REPO_ROOT}/tools/lib/gates.sh"

usage() {
  cat <<EOF
Usage: tools/55_compat_sweep.sh [--library=DIR] [--emulator=PATH] [--rom-dir=DIR]
                                [--frames=N] [--limit=N] [--dry-run] [--help]

  --library=DIR   Library with library.json and disks/ (default: ${DEFAULT_LIBRARY}).
  --emulator=PATH a2emu built by tools/15_build_a2emu_norom.sh (default: build/a2emu-norom/a2emu).
  --rom-dir=DIR   Folder with ${REQUIRED_ROMS[*]} (default: roms/).
  --frames=N      Frames to run each boot before judging it (default 1800 = 30 s).
  --limit=N       Sweep only the first N boot disks.
  --dry-run       Check inputs only.
  --help          This text.
EOF
}

LIBRARY="${DEFAULT_LIBRARY}"
EMULATOR="${DEFAULT_EMULATOR}"
ROM_DIR="${DEFAULT_ROM_DIR}"
SWEEP_ARGS=()
DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --help|-h) usage; exit 0 ;;
    --library=*) LIBRARY="${arg#--library=}" ;;
    --emulator=*) EMULATOR="${arg#--emulator=}" ;;
    --rom-dir=*) ROM_DIR="${arg#--rom-dir=}" ;;
    --frames=*|--limit=*)
      if [[ ! "${arg#*=}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: ${arg%%=*} needs a positive number" >&2; exit 2
      fi
      SWEEP_ARGS+=("${arg}") ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "ERROR: unknown option ${arg}" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "${LOG_DIR}"
echo "=== 55_compat_sweep.sh $(date '+%Y-%m-%d %H:%M:%S %z') library=${LIBRARY}" >> "${LOG_FILE}"

# ── Gate 0: inputs ──────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 0] Inputs"
if ! command -v python3 >/dev/null 2>&1; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "python3 is missing. Install the Xcode command-line tools: xcode-select --install" 3
fi
if [[ ! -x "${EMULATOR}" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "No ${EMULATOR}. Run tools/15_build_a2emu_norom.sh." 2
fi
if ! "${EMULATOR}" --help 2>&1 | grep -q -- "--snapshot-frame"; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "${EMULATOR} has no --snapshot-frame. Rebuild with tools/15_build_a2emu_norom.sh." 2
fi
for rom in "${REQUIRED_ROMS[@]}"; do
  if [[ ! -f "${ROM_DIR}/${rom}" ]]; then
    fail_gate "Gate 0: Inputs" "${gate_start}" "No ${ROM_DIR}/${rom}. Run tools/05_fetch_rom.sh and tools/05_fetch_rom.sh --model=iie." 2
  fi
done
if [[ ! -f "${LIBRARY}/library.json" ]]; then
  fail_gate "Gate 0: Inputs" "${gate_start}" "No ${LIBRARY}/library.json. Run tools/07_fetch_edu_library.sh, then tools/50_library.sh." 2
fi
pass_gate "Gate 0: Inputs" "${gate_start}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[dry-run] would sweep ${LIBRARY} with ${EMULATOR} and rebuild the catalog"
  print_summary "PASSED"
  exit 0
fi

# ── Gate 1: sweep ───────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 1] Boot every title (II+, then //e where needed)"
if [[ -f "${LIBRARY}/compat.json" ]]; then
  backup="${LIBRARY}/compat.json.backup-$(date +%Y%m%d_%H%M%S)"
  cp "${LIBRARY}/compat.json" "${backup}"
  echo "  previous results backed up to ${backup}"
fi
if ! python3 -I "${SWEEP_TOOL}" --library="${LIBRARY}" --emulator="${EMULATOR}" --rom-dir="${ROM_DIR}" \
  "${SWEEP_ARGS[@]+"${SWEEP_ARGS[@]}"}" 2>&1 | tee -a "${LOG_FILE}"; then
  fail_gate "Gate 1: Sweep" "${gate_start}" "The sweep stopped; see ${LOG_FILE}."
fi
pass_gate "Gate 1: Sweep" "${gate_start}"

# ── Gate 2: results ─────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 2] compat.json is complete"
if ! python3 -I - "${LIBRARY}" <<'PY' 2>&1 | tee -a "${LOG_FILE}"
import json, sys
library = sys.argv[1]
results = json.load(open(f"{library}/compat.json"))["results"]
allowed = {"IIplus64K", "IIe128K", "noboot", "unknown"}
bad = [sha for sha, r in results.items() if r.get("requirement") not in allowed or not r.get("detail")]
if bad:
    sys.exit(f"{len(bad)} results without a valid requirement and detail, e.g. {bad[0]}")
print(f"  {len(results)} boot disks judged")
PY
then
  fail_gate "Gate 2: Results" "${gate_start}" "compat.json is incomplete; see ${LOG_FILE}."
fi
pass_gate "Gate 2: Results" "${gate_start}"

# ── Gate 3: catalog ─────────────────────────────────────────────────
gate_start="$(date +%s)"
echo "[Gate 3] Rebuild the catalog with the sweep results"
if ! bash "${CATALOG_SCRIPT}" --library="${LIBRARY}" >> "${LOG_FILE}" 2>&1; then
  fail_gate "Gate 3: Catalog" "${gate_start}" "tools/50_library.sh failed; see ${LOG_FILE}."
fi
if ! python3 -I - "${LIBRARY}" <<'PY' 2>&1 | tee -a "${LOG_FILE}"
import collections, json, sys
titles = json.load(open(f"{sys.argv[1]}/library.json"))["titles"]
counts = collections.Counter(t["requirement"] for t in titles)
swept = sum(1 for t in titles if t["requirementSource"] == "sweep")
print("  " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) + f"; {swept} decided by the sweep")
sys.exit(0 if swept else "no title took its requirement from the sweep")
PY
then
  fail_gate "Gate 3: Catalog" "${gate_start}" "The catalog did not pick up compat.json."
fi
pass_gate "Gate 3: Catalog" "${gate_start}"

print_summary "PASSED"
