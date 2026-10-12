#!/bin/bash
# Shared verification-gate helpers. Source after setting:
#   LOG_FILE        log that fail_gate tails for diagnostics
#   SUMMARY_TITLE   heading for the summary table
# Bash 3.2 compatible (macOS /bin/bash).

readonly GATE_DIAG_TAIL_LINES=40

GATE_NAMES=()
GATE_STATUS=()
GATE_SECONDS=()
ARTIFACTS=()
SCRIPT_START="$(date +%s)"

record_gate() {
  GATE_NAMES+=("$1")
  GATE_STATUS+=("$2")
  GATE_SECONDS+=("$3")
}

print_summary() {
  local overall="$1" i
  echo
  echo "══════════════════════════════════════════════════════════"
  echo "EXECUTION SUMMARY — ${SUMMARY_TITLE}"
  echo "──────────────────────────────────────────────────────────"
  printf "%-48s %-8s %s\n" "Step" "Status" "Duration"
  echo "──────────────────────────────────────────────────────────"
  for i in "${!GATE_NAMES[@]}"; do
    printf "%-48s %-8s %ss\n" "${GATE_NAMES[$i]}" "${GATE_STATUS[$i]}" "${GATE_SECONDS[$i]}"
  done
  echo "──────────────────────────────────────────────────────────"
  echo "Overall: ${overall} | Total time: $(( $(date +%s) - SCRIPT_START ))s"
  echo "══════════════════════════════════════════════════════════"
}

print_artifacts() {
  local item
  echo "Artifacts completed so far:"
  if [[ ${#ARTIFACTS[@]} -eq 0 ]]; then
    echo "  (none)"
    return
  fi
  for item in "${ARTIFACTS[@]}"; do echo "  - ${item}"; done
}

pass_gate() {
  record_gate "$1" "PASSED" "$(( $(date +%s) - $2 ))"
  echo "  [PASSED] $1"
}

skip_gate() {
  record_gate "$1" "SKIPPED" 0
  echo "  [SKIPPED] $1 — $2"
}

# Same slug rule as disk_slug() in tools/10_analyze.py: work/<slug>/ per disk.
disk_slug() {
  local slug
  slug="$(basename "$1" | sed -E 's/\.[^.]+$//' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  echo "${slug:-disk}"
}

# fail_gate NAME START_EPOCH REPAIR_TEXT [EXIT_CODE]
fail_gate() {
  local gate_name="$1" started="$2" repair="$3" exit_code="${4:-1}"
  record_gate "${gate_name}" "FAILED" "$(( $(date +%s) - started ))"
  echo "  [FAILED] ${gate_name}" >&2
  echo >&2
  print_artifacts >&2
  echo >&2
  echo "Diagnostics (last ${GATE_DIAG_TAIL_LINES} lines of ${LOG_FILE}):" >&2
  tail -n "${GATE_DIAG_TAIL_LINES}" "${LOG_FILE}" >&2 || true
  echo >&2
  echo "Repair:" >&2
  echo "${repair}" >&2
  print_summary "FAILED"
  exit "${exit_code}"
}
