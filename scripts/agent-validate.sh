#!/usr/bin/env bash

# Aggregate lint, type-check, unit, and Playwright suites with consistent logging.
# Usage: ./scripts/agent-validate.sh [--skip-e2e] [--skip-unit]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SKIP_UNIT=false
SKIP_E2E=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-unit)
      SKIP_UNIT=true
      shift
      ;;
    --skip-e2e)
      SKIP_E2E=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

log_divider() {
  printf '\n[%s]\n' "$1"
}

run_step() {
  local label="$1"
  shift

  log_divider "${label}"
  if "$@"; then
    echo "${label} succeeded"
  else
    local exit_code=$?
    echo "${label} failed (exit ${exit_code})"
    exit "${exit_code}"
  fi
}

cd "${REPO_ROOT}"

TEMP_DIR="${REPO_ROOT}/.tmp/agent-validation"
mkdir -p "${TEMP_DIR}"
export TMPDIR="${TEMP_DIR}"
export PLAYWRIGHT_CACHE_DIR="${REPO_ROOT}/.cache/playwright"
mkdir -p "${PLAYWRIGHT_CACHE_DIR}"

run_step "Linting" pnpm lint
run_step "Type checking" pnpm type-check

if [[ "${SKIP_UNIT}" == "false" ]]; then
  run_step "Unit tests" pnpm --filter @ai-dev-platform/web test
else
  echo "Skipping unit tests (--skip-unit)"
fi

if [[ "${SKIP_E2E}" == "false" ]]; then
  run_step "Playwright tests" pnpm --filter @ai-dev-platform/web test:e2e
else
  echo "Skipping Playwright tests (--skip-e2e)"
fi

echo
echo "All selected validation steps finished successfully."
