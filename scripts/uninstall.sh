#!/usr/bin/env bash
# Uninstall helper for the AI Dev Platform. Cleans repository artifacts,
# optional developer-home caches, and (optionally) runs terraform destroy for
# each environment before wiping local Terraform state.

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE=0
DRY_RUN=0
INCLUDE_HOME=0
DESTROY_TERRAFORM=0
SUMMARY_FILE="$ROOT_DIR/uninstall-terraform-summary.json"
SKIP_REPO=0
SKIP_TERRAFORM_LOCAL=0
SKIP_HOME=0
SKIP_DESTROY=0
BACKUP_DIR=""
PARALLEL_JOBS=4
TELEMETRY=0
FULL_RESET=0
HOST_SCRIPT_CREATED=0
HOST_SCRIPT_PATH_UNIX=""
HOST_INVOKER_PATH_UNIX=""
START_TIME=$SECONDS
declare -a DRY_RUN_REPORT=()

shopt -s nullglob

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
  elif command -v python >/dev/null 2>&1 && [[ "$(python -c 'import sys;print(sys.version_info[0])')" == "3" ]]; then
    PYTHON_BIN="python"
  else
    PYTHON_BIN=""
  fi
fi

on_error() {
  local exit_code="$1"
  local line="$2"
  echo "Error: uninstall aborted at line $line (exit code $exit_code)." >&2
  exit "$exit_code"
}

trap 'on_error $? $LINENO' ERR

timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

json_escape() {
  if [[ -n "$PYTHON_BIN" ]]; then
    "$PYTHON_BIN" - <<'PY' "$1"
import json, sys
print(json.dumps(sys.argv[1])[1:-1])
PY
    return
  fi
  local value="$1"
  local output=""
  local length=${#value}
  local i char ascii hex
  for (( i=0; i<length; i++ )); do
    char=${value:i:1}
    case "$char" in
      '\\') output+='\\\\' ;;
      '"') output+='\\"' ;;
      $'\b') output+='\\b' ;;
      $'\f') output+='\\f' ;;
      $'\n') output+='\\n' ;;
      $'\r') output+='\\r' ;;
      $'\t') output+='\\t' ;;
      *)
        LC_CTYPE=C printf -v ascii '%d' "'${char}"
        if (( ascii < 0x20 || ascii == 0x7f )); then
          printf -v hex '\\u%04X' "$ascii"
          output+="$hex"
        else
          output+="$char"
        fi ;;
    esac
  done
  printf '%s' "$output"
}

log_phase() {
  local message="$1"
  local elapsed=$((SECONDS - START_TIME))
  printf '[%s] %s (elapsed %ss)\n' "$(date '+%H:%M:%S')" "$message" "$elapsed"
}

telemetry_emit() {
  (( TELEMETRY )) || return 0
  local event="$1"
  local status="$2"
  local detail="$3"
  local json_detail=""
  if [[ -n "$detail" ]]; then
    json_detail=",\"detail\":\"$(json_escape "$detail")\""
  fi
  printf '{"timestamp":"%s","event":"%s","status":"%s"%s}\n' "$(timestamp)" "$(json_escape "$event")" "$(json_escape "$status")" "$json_detail"
}

usage() {
  cat <<'USAGE'
Usage: ./scripts/uninstall.sh [options]

Options:
  --skip-repo         Do not delete repository artifacts.
  --skip-terraform-local
                      Do not delete local Terraform state/cache.
  --skip-home         Do not delete items under $HOME even if --include-home set.
  --skip-destroy-cloud
                      Disable terraform destroy even if --destroy-cloud passed.
  --force             Skip interactive confirmation.
  --dry-run           Show what would be removed without deleting anything.
  --include-home      Also remove Codex/Cursor caches under $HOME.
  --destroy-cloud     Run `terraform destroy` in infra/terraform/envs/* before cleaning files.
  --full-reset        Uninstall Cursor, Docker Desktop, and remove known WSL distributions in addition to repo cleanup.
  --backup-dir <path> Create tar.gz backups of targets before deletion.
  --parallel <n>      Number of parallel cleanup workers (default: 4).
  --telemetry         Emit JSON telemetry lines for key events.
  -h, --help          Show this message.

Examples:
  ./scripts/uninstall.sh --dry-run
  ./scripts/uninstall.sh --include-home --destroy-cloud
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-repo) SKIP_REPO=1; shift ;;
    --skip-terraform-local) SKIP_TERRAFORM_LOCAL=1; shift ;;
    --skip-home) SKIP_HOME=1; INCLUDE_HOME=0; shift ;;
    --skip-destroy-cloud) SKIP_DESTROY=1; DESTROY_TERRAFORM=0; shift ;;
    --backup-dir)
      BACKUP_DIR="$2"; shift 2 ;;
    --parallel)
      PARALLEL_JOBS="$2"; shift 2 ;;
    --telemetry) TELEMETRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --include-home) INCLUDE_HOME=1; shift ;;
    --destroy-cloud) DESTROY_TERRAFORM=1; shift ;;
    --full-reset)
      FULL_RESET=1
      FORCE=1
      INCLUDE_HOME=1
      SKIP_HOME=0
      DESTROY_TERRAFORM=1
      SKIP_DESTROY=0
      SKIP_REPO=0
      SKIP_TERRAFORM_LOCAL=0
      shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

cd "$ROOT_DIR"

if [[ ! -f "$ROOT_DIR/package.json" ]]; then
  echo "Error: script must be run from the repository root." >&2
  exit 1
fi

if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || (( PARALLEL_JOBS < 1 )); then
  echo "Invalid --parallel value; using 4." >&2
  PARALLEL_JOBS=4
fi

WAIT_N_AVAILABLE=0
if help wait 2>/dev/null | grep -q -- '-n'; then
  WAIT_N_AVAILABLE=1
fi
if (( PARALLEL_JOBS > 1 && ! WAIT_N_AVAILABLE )); then
  echo "Note: current Bash does not support wait -n; running cleanup sequentially." >&2
  PARALLEL_JOBS=1
fi

BACKUP_ENABLED=0
if [[ -n "$BACKUP_DIR" ]]; then
  mkdir -p "$BACKUP_DIR"
  BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"
  BACKUP_ENABLED=1
fi

REPO_ENABLED=$(( SKIP_REPO ? 0 : 1 ))
TERRAFORM_LOCAL_ENABLED=$(( SKIP_TERRAFORM_LOCAL ? 0 : 1 ))
DESTROY_TERRAFORM=$(( SKIP_DESTROY ? 0 : DESTROY_TERRAFORM ))
DESTROY_ENABLED=$(( DESTROY_TERRAFORM ? 1 : 0 ))
HOME_ENABLED=0
if (( INCLUDE_HOME )) && (( ! SKIP_HOME )); then
  HOME_ENABLED=1
else
  INCLUDE_HOME=0
fi

telemetry_emit "uninstall.start" "begin" "dry_run=$DRY_RUN"
log_phase "Uninstall script initialised (dry-run=$DRY_RUN, force=$FORCE)"

interactive_menu() {
  (( FORCE )) && return
  [[ -t 0 ]] || return
  while true; do
    echo ""
    echo "Configure cleanup:"
    printf "  1) Repository cleanup           : %s\n" $([[ $REPO_ENABLED -eq 1 ]] && echo "ON" || echo "OFF")
    printf "  2) Terraform local cleanup      : %s\n" $([[ $TERRAFORM_LOCAL_ENABLED -eq 1 ]] && echo "ON" || echo "OFF")
    printf "  3) Home cache cleanup           : %s\n" $([[ $HOME_ENABLED -eq 1 ]] && echo "ON" || echo "OFF")
    printf "  4) Terraform destroy (cloud)    : %s\n" $([[ $DESTROY_ENABLED -eq 1 ]] && echo "ON" || echo "OFF")
    printf "  5) Backup directory             : %s\n" $([[ $BACKUP_ENABLED -eq 1 ]] && echo "$BACKUP_DIR" || echo "Disabled")
    printf "  6) Parallel workers             : %s\n" "$PARALLEL_JOBS"
    echo "  7) Continue"
    read -r -p "Choose an option to toggle/configure: " choice
    case "$choice" in
      1) REPO_ENABLED=$(( REPO_ENABLED ? 0 : 1 )) ;;
      2) TERRAFORM_LOCAL_ENABLED=$(( TERRAFORM_LOCAL_ENABLED ? 0 : 1 )) ;;
      3)
         if (( HOME_ENABLED )); then
           HOME_ENABLED=0; INCLUDE_HOME=0
         else
           HOME_ENABLED=1; INCLUDE_HOME=1
         fi ;;
      4) DESTROY_ENABLED=$(( DESTROY_ENABLED ? 0 : 1 )) ;;
      5)
         if (( BACKUP_ENABLED )); then
           BACKUP_ENABLED=0; BACKUP_DIR=""
         else
           read -r -p "Enter backup directory path: " input_dir
           if [[ -n "$input_dir" ]]; then
             BACKUP_DIR="$(cd "$(dirname "$input_dir")" && pwd)/$(basename "$input_dir")"
             mkdir -p "$BACKUP_DIR"
             BACKUP_ENABLED=1
           fi
         fi ;;
      6)
         read -r -p "Parallel workers (current $PARALLEL_JOBS): " workers
         if [[ "$workers" =~ ^[0-9]+$ ]] && (( workers > 0 )); then
           PARALLEL_JOBS=$workers
         else
           echo "Invalid worker count."
         fi ;;
      7) break ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

if (( FULL_RESET )); then
  log_phase "Full reset requested; skipping interactive configuration prompts."
else
  interactive_menu
fi

timestamp_file() {
  date +"%Y%m%d-%H%M%S"
}

perform_backup() {
  local category="$1"; shift
  (( BACKUP_ENABLED )) || return
  (( DRY_RUN )) && { log_phase "Skipping backup for $category during dry-run"; telemetry_emit "backup.skip" "dry-run" "$category"; return; }
  local -a to_backup=()
  local path
  for path in "$@"; do
    [[ -e "$path" || -L "$path" ]] && to_backup+=("$path")
  done
  (( ${#to_backup[@]} )) || return
  local archive="$BACKUP_DIR/${category}-$(timestamp_file).tar.gz"
  log_phase "Creating backup archive for $category -> $archive"
  if tar -czf "$archive" -- "${to_backup[@]}" 2>>/tmp/uninstall-backup.log; then
    telemetry_emit "backup.${category}" "ok" "$archive"
  else
    telemetry_emit "backup.${category}" "error" "$archive"
    echo "Warning: backup for $category failed (see /tmp/uninstall-backup.log)." >&2
  fi
}

prompt() {
  local message="$1"
  if (( FORCE )); then
    return 0
  fi
  if ! read -r -p "$message [y/N] " response; then
    return 1
  fi
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

remove_target() {
  local category="$1"
  local target="$2"
  if [[ -z "$target" ]]; then
    return
  fi
  local exists=0
  if [[ -e "$target" || -L "$target" ]]; then
    exists=1
  fi
  if (( DRY_RUN )); then
    if (( exists )); then
      echo "[dry-run][$category] rm -rf $target"
      DRY_RUN_REPORT+=("$category would remove: $target")
      telemetry_emit "dry-run.$category" "present" "$target"
    else
      echo "[dry-run][$category] skip missing $target"
      DRY_RUN_REPORT+=("$category missing: $target")
      telemetry_emit "dry-run.$category" "missing" "$target"
    fi
  else
    if (( exists )); then
      rm -rf "$target"
      echo "Removed [$category] $target"
      telemetry_emit "delete.$category" "ok" "$target"
    else
      echo "Skipped [$category] $target (not found)"
      telemetry_emit "delete.$category" "missing" "$target"
    fi
  fi
}

process_targets() {
  local category="$1"; shift
  local -a targets=("$@")
  (( ${#targets[@]} )) || return
  log_phase "Processing $category targets (${#targets[@]})"
  telemetry_emit "process.$category" "begin" "${#targets[@]}"
  if (( BACKUP_ENABLED )) && (( ! DRY_RUN )); then
    perform_backup "$category" "${targets[@]}"
  fi
  if (( DRY_RUN )) || (( PARALLEL_JOBS <= 1 )); then
    local path
    for path in "${targets[@]}"; do
      remove_target "$category" "$path"
    done
  else
    local active=0 path
    for path in "${targets[@]}"; do
      {
        remove_target "$category" "$path"
      } &
      active=$((active+1))
      if (( active >= PARALLEL_JOBS )); then
        wait -n
        active=$((active-1))
      fi
    done
    wait
  fi
  telemetry_emit "process.$category" "end" "${#targets[@]}"
}

repo_targets=(
  "$ROOT_DIR/node_modules"
  "$ROOT_DIR/.pnpm-store"
  "$ROOT_DIR/.turbo"
  "$ROOT_DIR/.playwright"
  "$ROOT_DIR/.cache"
  "$ROOT_DIR/.pnpm-debug.log"
  "$ROOT_DIR/.onboarding_complete"
  "$ROOT_DIR/tmp"
  "$ROOT_DIR/artifacts"
  "$ROOT_DIR/apps/web/node_modules"
  "$ROOT_DIR/apps/web/.next"
  "$ROOT_DIR/apps/web/playwright-report"
  "$ROOT_DIR/apps/web/test-results"
  "$ROOT_DIR/apps/web/playwright-report.zip"
  "$ROOT_DIR/packages"/*/node_modules
  "$ROOT_DIR/.git/hooks/pre-commit"
  "$ROOT_DIR/.git/hooks/pre-push"
)

terraform_local_targets=(
  "$ROOT_DIR/infra/terraform/.terraform"
  "$ROOT_DIR/infra/terraform/.terraform.lock.hcl"
  "$ROOT_DIR/infra/terraform/terraform.tfstate"
  "$ROOT_DIR/infra/terraform/terraform.tfstate.backup"
  "$ROOT_DIR/infra/terraform/envs"/*/.terraform
  "$ROOT_DIR/infra/terraform/envs"/*/.terraform.lock.hcl
  "$ROOT_DIR/infra/terraform/envs"/*/terraform.tfstate
  "$ROOT_DIR/infra/terraform/envs"/*/terraform.tfstate.backup
)

home_targets=(
  "$HOME/.cursor"
  "$HOME/.codex"
  "$HOME/.cache/Cursor"
  "$HOME/.cache/ms-playwright"
  "$HOME/.cache/pnpm"
  "$HOME/.local/share/pnpm"
  "$HOME/.pnpm-store"
  "$HOME/.turbo"
  "$HOME/.npm"
  "$HOME/.config/gcloud"
  "$HOME/.terraform.d"
)

declare -a summaries=()
declare -a json_entries=()

detect_backend_type() {
  local env_dir="$1"
  local backend="unknown"

  if [[ -n "$PYTHON_BIN" ]]; then
    backend=$("$PYTHON_BIN" - <<'PY' "$env_dir" 2>/dev/null || true
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
pattern = re.compile(r'backend\s*"([^"]+)"')
for tf_file in sorted(root.glob("*.tf")):
    try:
        text = tf_file.read_text(encoding="utf-8")
    except OSError:
        continue
    match = pattern.search(text)
    if match:
        print(match.group(1))
        break
PY
)
  elif command -v python3 >/dev/null 2>&1; then
    backend=$(python3 - <<'PY' "$env_dir" 2>/dev/null || true
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
pattern = re.compile(r'backend\s*"([^"]+)"')
for tf_file in sorted(root.glob("*.tf")):
    try:
        text = tf_file.read_text(encoding="utf-8")
    except OSError:
        continue
    match = pattern.search(text)
    if match:
        print(match.group(1))
        break
PY
)
  else
    local tf_files=()
    while IFS= read -r tf_file; do
      tf_files+=("$tf_file")
    done < <(find "$env_dir" -maxdepth 1 -type f -name '*.tf' 2>/dev/null)
    if (( ${#tf_files[@]} )); then
      backend=$(grep -hE 'backend[[:space:]]+"[^"]+"' "${tf_files[@]}" 2>/dev/null | head -n 1 | sed -nE 's/.*backend[[:space:]]+"([^"]+)".*/\1/p')
    fi
  fi

  [[ -n "$backend" ]] || backend="unknown"
  printf '%s\n' "$backend"
}

append_summary() {
  local env="$1" status="$2" message="$3" backend="$4"
  summaries+=("$env: $status - $message (backend: $backend)")
  json_entries+=("    {\"environment\":\"$(json_escape "$env")\",\"status\":\"$(json_escape "$status")\",\"backend\":\"$(json_escape "$backend")\",\"message\":\"$(json_escape "$message")\"}")
}

get_backend() {
  local env_dir="$1"
  local backend_file="$env_dir/backend.tf"
  local backend="unknown"
  if [[ -f "$backend_file" ]]; then
    backend=$(detect_backend_type "$env_dir")
    backend=${backend:-unknown}
  fi
  printf '%s\n' "$backend"
}

run_terraform_destroy() {
  local env_dir="$1" backend
  backend=$(get_backend "$env_dir")
  echo "-- Terraform destroy in $env_dir (backend: $backend)"
  case "$backend" in
    s3|gcs|azurerm|remote|http)
      echo "  Remote backend detected ($backend); ensure remote state is cleaned if destroy fails." >&2
      ;;
    unknown)
      echo "  Backend type could not be confirmed; assuming remote backend for safety." >&2
      backend="unknown"
      ;;
  esac

  if (( DRY_RUN )); then
    append_summary "$env_dir" "skipped" "dry-run" "$backend"
    return
  fi

  if ! command -v terraform >/dev/null 2>&1; then
    echo "Terraform binary not found. Skipping cloud destruction for $env_dir" >&2
    append_summary "$env_dir" "skipped" "terraform unavailable" "$backend"
    return
  fi

  pushd "$env_dir" >/dev/null
  if ! terraform init -upgrade >/dev/null; then
    echo "terraform init failed in $env_dir" >&2
    append_summary "$env_dir" "failure" "terraform init failed" "$backend"
    popd >/dev/null
    return
  fi

  if terraform destroy -auto-approve; then
    if terraform state list >/dev/null 2>&1; then
      if STATE_ENTRIES=$(terraform state list); then
        if [[ -n "$STATE_ENTRIES" ]]; then
          echo "  Warning: residual state detected for $env_dir" >&2
          append_summary "$env_dir" "warning" "destroy succeeded but state not empty" "$backend"
        else
          append_summary "$env_dir" "success" "destroy succeeded" "$backend"
        fi
      else
        append_summary "$env_dir" "success" "destroy succeeded" "$backend"
      fi
    else
      append_summary "$env_dir" "success" "destroy succeeded" "$backend"
    fi
  else
    echo "terraform destroy failed in $env_dir" >&2
    append_summary "$env_dir" "failure" "destroy failed" "$backend"
  fi
  popd >/dev/null
}

generate_host_cleanup_script() {
  local host_root="/mnt/c/ProgramData/ai-dev-platform"
  if [[ ! -d "$host_root" ]]; then
    mkdir -p "$host_root"
  fi
  local script_path="$host_root/uninstall-host.ps1"
  local invoker_path="$host_root/invoke-uninstall-host.ps1"
  cat <<'POWERSHELL' >"$script_path"
[CmdletBinding()]
param(
    [switch]$Elevated
)

function Restart-Elevated {
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$MyInvocation.MyCommand.Definition,'-Elevated')
    Start-Process -FilePath 'PowerShell.exe' -ArgumentList $args -Verb RunAs
    exit
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if ($Elevated) {
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Restart-Elevated
    }
} else {
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Restart-Elevated
    }
}

function Write-Info { param($Message) Write-Host "[host] $Message" -ForegroundColor Cyan }
function Write-Ok   { param($Message) Write-Host "[host] $Message" -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host "[host] $Message" -ForegroundColor Yellow }
function Write-Err  { param($Message) Write-Host "[host] $Message" -ForegroundColor Red }

Write-Info "Waiting for active WSL sessions to exit..."
for ($i = 0; $i -lt 120; $i++) {
    if (-not (Get-Process -Name 'wsl' -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Seconds 1
}

function Invoke-WingetUninstall {
    param([string]$PackageId)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn "winget not available; skipping $PackageId."
        return
    }
    Write-Info "Uninstalling $PackageId via winget..."
    & winget uninstall --id $PackageId --silent --accept-source-agreements --accept-package-agreements *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "winget removed $PackageId."
    } else {
        Write-Warn "winget uninstall for $PackageId returned exit code $LASTEXITCODE."
    }
}

$wingetTargets = @(
    'Cursor.Cursor',
    'Docker.DockerDesktop',
    'Docker.DockerDesktop.App',
    'Docker.DockerDesktopEdge'
)
foreach ($pkg in $wingetTargets) {
    Invoke-WingetUninstall $pkg
}

Write-Info "Stopping Docker Desktop services..."
Get-Process -Name 'Docker Desktop','DockerCli','com.docker.service' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
if (Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue) {
    Stop-Service -Name 'com.docker.service' -Force -ErrorAction SilentlyContinue
}

$registered = (& wsl.exe -l -q 2>$null) -replace "`0","" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$knownDistros = @('Ubuntu','Ubuntu-22.04','Ubuntu-20.04','Ubuntu-24.04','ai-dev-platform','Ubuntu-22.04-ai-dev-platform')
foreach ($distro in $knownDistros) {
    if ($registered -contains $distro) {
        Write-Info "Removing WSL distribution '$distro'..."
        & wsl.exe --terminate $distro 2>$null | Out-Null
        & wsl.exe --unregister $distro 2>$null | Out-Null
        Write-Ok "WSL distribution '$distro' removed."
    }
}

function Remove-Tree {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (Test-Path $Path) {
        Write-Info "Deleting $Path"
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Ok "Deleted $Path"
        } catch {
            Write-Warn "Failed to delete $Path: $($_.Exception.Message)"
        }
    }
}

$paths = @(
    "$env:ProgramData\ai-dev-platform",
    "$env:LOCALAPPDATA\ai-dev-platform",
    "$env:LOCALAPPDATA\Cursor",
    "$env:LOCALAPPDATA\Programs\Cursor",
    "$env:APPDATA\Cursor",
    "$env:UserProfile\.cursor",
    "$env:UserProfile\ai-dev-platform",
    "$env:UserProfile\.pnpm-store",
    "$env:UserProfile\.turbo",
    "$env:UserProfile\AppData\Local\Docker",
    "$env:UserProfile\AppData\Roaming\Docker",
    "$env:ProgramData\DockerDesktop",
    "$env:ProgramData\Docker",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Docker Desktop.lnk",
    "$env:UserProfile\Desktop\Docker Desktop.lnk"
)
foreach ($path in $paths) {
    Remove-Tree $path
}

$envVars = @('INFISICAL_TOKEN','GH_TOKEN','WSLENV','DOCKER_CERT_PATH','DOCKER_HOST','DOCKER_DISTRO_NAME')
foreach ($name in $envVars) {
    [Environment]::SetEnvironmentVariable($name,$null,[EnvironmentVariableTarget]::User)
    [Environment]::SetEnvironmentVariable($name,$null,[EnvironmentVariableTarget]::Machine)
}

Write-Ok "Host cleanup complete. A reboot is recommended."
try {
    Remove-Item -Path $MyInvocation.MyCommand.Definition -Force
} catch {
    Write-Warn "Unable to delete cleanup script: $($_.Exception.Message)"
}
POWERSHELL
  cat <<'POWERSHELL' >"$invoker_path"
[CmdletBinding()]
param(
    [string]$ScriptPath = "$PSScriptRoot\uninstall-host.ps1"
)
if (-not (Test-Path $ScriptPath)) {
    Write-Error "Host cleanup script not found: $ScriptPath"
    exit 1
}
Start-Process -FilePath 'PowerShell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File', $ScriptPath -Verb RunAs
POWERSHELL
  chmod 0600 "$invoker_path"
  chmod 0600 "$script_path"
  HOST_SCRIPT_PATH_UNIX="$script_path"
  HOST_INVOKER_PATH_UNIX="$invoker_path"
  HOST_SCRIPT_CREATED=1
}

launch_host_cleanup_script() {
  (( HOST_SCRIPT_CREATED )) || return
  if ! command -v powershell.exe >/dev/null 2>&1; then
    local msg_path="$HOST_SCRIPT_PATH_UNIX"
    if command -v wslpath >/dev/null 2>&1; then
      msg_path=$(wslpath -w "$HOST_SCRIPT_PATH_UNIX")
    fi
    log_phase "PowerShell not available; run $msg_path manually with administrator privileges to finish host cleanup."
    return
  fi
  local win_path
  local invoker_win_path
  if command -v wslpath >/dev/null 2>&1; then
    win_path=$(wslpath -w "$HOST_SCRIPT_PATH_UNIX")
    invoker_win_path=$(wslpath -w "$HOST_INVOKER_PATH_UNIX")
  else
    win_path="C:\\ProgramData\\ai-dev-platform\\uninstall-host.ps1"
    invoker_win_path="C:\\ProgramData\\ai-dev-platform\\invoke-uninstall-host.ps1"
  fi
  if powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$invoker_win_path" >/dev/null 2>&1; then
    log_phase "Windows host cleanup launched (administrator approval required)."
  else
    local fallback="$win_path"
    if command -v wslpath >/dev/null 2>&1; then
      fallback=$(wslpath -w "$HOST_SCRIPT_PATH_UNIX")
    fi
    log_phase "Failed to launch Windows cleanup automatically. Run $fallback manually as administrator."
  fi
}

if ! prompt "This will remove generated artifacts from $ROOT_DIR. Proceed?"; then
  echo "Aborted."
  exit 0
fi

if (( DESTROY_ENABLED )); then
  log_phase "Beginning Terraform destruction"
  telemetry_emit "destroy.start" "begin" ""
  env_found=0
  for env_dir in "$ROOT_DIR"/infra/terraform/envs/*; do
    [[ -d "$env_dir" ]] || continue
    env_found=1
    run_terraform_destroy "$env_dir"
  done
  if (( ! env_found )); then
    echo "No Terraform environments found under infra/terraform/envs."
  fi
  if ((${#summaries[@]})); then
    echo "Terraform destruction summary:"
    printf '  - %s\n' "${summaries[@]}"
  fi
  if (( ! DRY_RUN )); then
    if ((${#json_entries[@]})); then
      {
        printf '[\n'
        total=${#json_entries[@]}
        for ((i=0; i<total; i++)); do
          printf '%s' "${json_entries[i]}"
          if (( i < total - 1 )); then
            printf ',\n'
          else
            printf '\n'
          fi
        done
        printf ']\n'
      } > "$SUMMARY_FILE"
      echo "Summary written to $SUMMARY_FILE"
    else
      if [[ -f "$SUMMARY_FILE" ]]; then
        rm -f "$SUMMARY_FILE"
        echo "No Terraform actions executed; removed existing $SUMMARY_FILE."
      else
        echo "No Terraform actions executed; skipping summary file."
      fi
    fi
  fi
  telemetry_emit "destroy.end" "complete" ""
fi

if (( REPO_ENABLED )); then
  process_targets "repo" "${repo_targets[@]}"
else
  log_phase "Repository cleanup skipped"
fi

if (( TERRAFORM_LOCAL_ENABLED )); then
  process_targets "terraform-local" "${terraform_local_targets[@]}"
else
  log_phase "Terraform local cleanup skipped"
fi

if (( HOME_ENABLED )); then
  if prompt "Also remove cached state under $HOME?"; then
    process_targets "home" "${home_targets[@]}"
  else
    log_phase "Home cache cleanup skipped by user"
  fi
else
  (( INCLUDE_HOME )) && log_phase "Home cleanup disabled by configuration"
fi

if (( DRY_RUN )) && ((${#DRY_RUN_REPORT[@]})); then
  echo ""
  echo "Dry-run summary:"
  printf '  - %s\n' "${DRY_RUN_REPORT[@]}"
fi

if (( FULL_RESET )); then
  if (( DRY_RUN )); then
    log_phase "Full reset requested (dry-run); Windows host script will not be generated."
  else
    log_phase "Preparing Windows host reset script."
    generate_host_cleanup_script
    launch_host_cleanup_script
  fi
fi

log_phase "Uninstall complete. Run ./scripts/setup-all.sh to reinstall when ready."
telemetry_emit "uninstall.complete" "success" "dry_run=$DRY_RUN"
