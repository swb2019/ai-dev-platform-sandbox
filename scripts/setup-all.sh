#!/usr/bin/env bash
# Composite setup helper: runs onboarding, infrastructure bootstrap, and
# repository hardening in sequence so new contributors can issue a single
# command. Each underlying script remains interactive and idempotent; this
# wrapper simply orchestrates the order and provides status messaging.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONBOARD_SCRIPT="$ROOT_DIR/scripts/onboard.sh"
BOOTSTRAP_SCRIPT="$ROOT_DIR/scripts/bootstrap-infra.sh"
HARDENING_SCRIPT="$ROOT_DIR/scripts/github-hardening.sh"
UPDATE_SCRIPT="$ROOT_DIR/scripts/update-editor-extensions.sh"
VERIFY_SCRIPT="$ROOT_DIR/scripts/verify-editor-extensions.sh"
LOCK_FILE="$ROOT_DIR/config/editor-extensions.lock.json"

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

run_step() {
  local label="$1" script_path="$2"
  if [[ ! -x "$script_path" ]]; then
    printf 'Error: step "%s" is missing or not executable (%s)\n' "$label" "$script_path" >&2
    exit 1
  fi
  log "Starting ${label}..."
  if bash "$script_path"; then
    log "Completed ${label}."
  else
    local status=$?
    printf '\n%s failed with exit status %d. Review the output above, resolve the issue, then rerun %s or this wrapper when ready.\n' "$label" "$status" "$script_path" >&2
    exit $status
  fi
}

cd "$ROOT_DIR"

log "AI Dev Platform consolidated setup"
log "Repository root: $ROOT_DIR"

TOOLCHAIN_SCRIPT="$ROOT_DIR/scripts/install-toolchain.sh"
if [[ -f "$TOOLCHAIN_SCRIPT" ]]; then
  log "Provisioning CLI prerequisites"
  # shellcheck disable=SC1090
  source "$TOOLCHAIN_SCRIPT"
  if ! install_toolchain_main; then
    echo "Unable to provision required tooling automatically. Review the messages above and retry once resolved." >&2
    exit 1
  fi
else
  log "Toolchain installer not found; skipping automatic CLI provisioning."
fi

run_step "Onboarding" "$ONBOARD_SCRIPT"
run_step "Infrastructure bootstrap" "$BOOTSTRAP_SCRIPT"
run_step "Repository hardening" "$HARDENING_SCRIPT"

log "All setup steps completed."
log "You can now run 'pnpm --filter @ai-dev-platform/web dev' or open your editor to start developing."
