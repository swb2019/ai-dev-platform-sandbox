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

STATE_DIR="${SETUP_STATE_DIR:-$ROOT_DIR/tmp}"
STATE_DIR="${STATE_DIR%/}"
if [[ -z "$STATE_DIR" ]]; then
  STATE_DIR="$ROOT_DIR/tmp"
fi
STATE_FILE="$STATE_DIR/setup-all.state"
declare -A STEP_STATE=()

ensure_state_dir() {
  if [[ -n "$STATE_DIR" && ! -d "$STATE_DIR" ]]; then
    mkdir -p -- "$STATE_DIR"
  fi
}

ensure_state_dir

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

warn() {
  printf '\n[%s] warning: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

die() {
  local message="$1"
  local code="${2:-1}"
  record_failure "$message"
  printf '\n[%s] error: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >&2
  exit "$code"
}

compute_checksum() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    warn "No SHA-256 utility available; skipping checksum calculation."
    printf '0000000000000000000000000000000000000000000000000000000000000000'
  fi
}

save_state() {
  mkdir -p -- "$STATE_DIR"
  if ((${#STEP_STATE[@]} == 0)); then
    rm -f "$STATE_FILE" "$STATE_FILE.bak"
    return
  fi
  local tmp data_file checksum
  tmp="$(mktemp "$STATE_DIR/setup-all.XXXXXX")"
  data_file="${tmp}.data"
  : >"$data_file"
  local key
  for key in "${!STEP_STATE[@]}"; do
    printf '%s=%s\n' "$key" "${STEP_STATE[$key]}" >>"$data_file"
  done
  LC_ALL=C sort -o "$data_file" "$data_file"
  local checksum
  checksum="$(compute_checksum "$data_file")"
  {
    printf '# checksum=%s\n' "$checksum"
    cat "$data_file"
  } >"$tmp"
  mv -f "$tmp" "$STATE_FILE"
  cp -f "$STATE_FILE" "$STATE_FILE.bak"
  rm -f "$data_file"
}

load_state() {
  STEP_STATE=()
  if [[ -f "$STATE_FILE" ]]; then
    local checksum expected data tmp
    checksum=""
    tmp="$(mktemp "$STATE_DIR/setup-all.XXXXXX")"
    while IFS= read -r line; do
      if [[ "$line" =~ ^#\ checksum=([a-fA-F0-9]+)$ ]]; then
        checksum="${BASH_REMATCH[1]}"
        continue
      fi
      printf '%s\n' "$line" >>"$tmp"
      IFS='=' read -r key value <<<"$line"
      [[ -z "$key" ]] && continue
      STEP_STATE["$key"]="$value"
    done <"$STATE_FILE"
    if [[ -n "$checksum" ]]; then
      expected="$(compute_checksum "$tmp")"
      if [[ "$expected" != "$checksum" ]]; then
        warn "setup-all state checksum mismatch; attempting to recover from backup."
        rm -f "$tmp"
        STEP_STATE=()
        if [[ -f "$STATE_FILE.bak" ]]; then
          rm -f "$tmp"
          cp "$STATE_FILE.bak" "$STATE_FILE"
          load_state
          return
        fi
        warn "State backup unavailable; continuing with empty state."
      fi
    fi
    rm -f "$tmp"
  fi
}

is_step_done() {
  local key="done_$1"
  [[ "${STEP_STATE[$key]:-}" == "1" ]]
}

mark_step() {
  local key="$1"
  STEP_STATE["done_${key}"]="1"
  STEP_STATE["done_${key}_timestamp"]="$(date -Iseconds)"
  save_state
}

record_failure() {
  local message="$1"
  STEP_STATE["last_failure"]="$(date -Iseconds) :: $message"
  save_state
}

clear_last_failure() {
  if [[ -n "${STEP_STATE[last_failure]:-}" ]]; then
    unset STEP_STATE["last_failure"]
    save_state
  fi
}

print_resume_summary() {
  if [[ -n "${STEP_STATE[last_failure]:-}" ]]; then
    warn "Previous setup attempt failed: ${STEP_STATE[last_failure]}"
  fi
  local completed=()
  local key
  for key in "${!STEP_STATE[@]}"; do
    if [[ "$key" == done_* && "${STEP_STATE[$key]}" == "1" ]]; then
      completed+=("${key#done_}")
    fi
  done
  if ((${#completed[@]} > 0)); then
    log "Completed steps detected: ${completed[*]}"
  fi
}

execute_step() {
  local key="$1" label="$2"
  shift 2
  if is_step_done "$key"; then
    log "Skipping ${label} (already completed)."
    return 0
  fi
  log "Starting ${label}..."
  if "$@"; then
    log "Completed ${label}."
    mark_step "$key"
    return 0
  fi
  local status=$?
  record_failure "${label} failed with exit status ${status}"
  printf '\n%s failed with exit status %d. Review the output above, resolve the issue, then rerun this script.\n' "$label" "$status" >&2
  exit "$status"
}

run_step() {
  local label="$1" script_path="$2" key="$3"
  if [[ -z "$key" ]]; then
    die "Internal error: missing state key for step \"${label}\"."
  fi
  if [[ ! -f "$script_path" ]]; then
    die "Step \"${label}\" is missing (${script_path})."
  fi
  execute_step "$key" "$label" bash "$script_path"
}

if [[ "${RESET_SETUP_STATE:-0}" == "1" ]]; then
  rm -f "$STATE_FILE"
fi
mkdir -p -- "$STATE_DIR"
load_state
print_resume_summary

is_wsl() {
  [[ -v WSL_DISTRO_NAME ]] || grep -qi microsoft /proc/version 2>/dev/null
}

ensure_system_prereqs() {
  log "Ensuring base system packages are available"
  if command -v apt-get >/dev/null 2>&1; then
    local packages=(
      build-essential
      ca-certificates
      curl
      git
      pkg-config
      python3
      python3-pip
      python3-venv
      unzip
    )
    local missing=()
    local pkg
    for pkg in "${packages[@]}"; do
      if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        missing+=("$pkg")
      fi
    done
    if ((${#missing[@]} == 0)); then
      log "Required Debian packages already installed."
      return 0
    fi

    local sudo_cmd=""
    if command -v sudo >/dev/null 2>&1 && [[ ${EUID:-0} -ne 0 ]]; then
      sudo_cmd="sudo"
    elif [[ ${EUID:-0} -ne 0 ]]; then
      warn "Missing sudo privileges; install packages manually: ${missing[*]}"
      return 1
    fi

    log "Installing Debian packages: ${missing[*]}"
    if [[ -n "$sudo_cmd" ]]; then
      $sudo_cmd apt-get update -y
      DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get install -y "${missing[@]}"
    else
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    local packages=(
      gcc
      gcc-c++
      make
      git
      curl
      pkgconf-pkg-config
      python3
      python3-pip
      unzip
    )
    local sudo_cmd=""
    if command -v sudo >/dev/null 2>&1 && [[ ${EUID:-0} -ne 0 ]]; then
      sudo_cmd="sudo"
    elif [[ ${EUID:-0} -ne 0 ]]; then
      warn "Missing sudo privileges; install packages manually using dnf."
      return 1
    fi
    log "Installing Fedora/RHEL prerequisites via dnf"
    if [[ -n "$sudo_cmd" ]]; then
      $sudo_cmd dnf install -y "${packages[@]}"
    else
      dnf install -y "${packages[@]}"
    fi
    return 0
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    refresh_homebrew_path
    if ! ensure_homebrew; then
      warn "Unable to install Homebrew automatically. Install it from https://brew.sh and re-run."
      return 1
    fi
    local packages=(
      git
      coreutils
      curl
      wget
      python
      pkg-config
      unzip
    )
    local missing=()
    local pkg
    for pkg in "${packages[@]}"; do
      if ! brew list --versions "$pkg" >/dev/null 2>&1; then
        missing+=("$pkg")
      fi
    done
    if ((${#missing[@]} > 0)); then
      log "Installing Homebrew packages: ${missing[*]}"
      brew update
      brew install "${missing[@]}"
    else
      log "Required Homebrew packages already installed."
    fi
    return 0
  else
    warn "Unable to detect a supported package manager; install prerequisite build tools manually."
  fi
  return 1
}

describe_environment() {
  if is_wsl; then
    log "Detected Windows Subsystem for Linux environment ($(uname -r))."
    log "Ensure Docker Desktop has WSL 2 integration enabled for this distro."
  else
    log "Running on $(uname -s) $(uname -m)."
  fi
}

refresh_homebrew_path() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    return 0
  fi
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    return 0
  fi
  if [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$(uname -s)" != "Darwin" ]]; then
    return 1
  fi
  log "Homebrew not detected; attempting installation"
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl is required to install Homebrew automatically."
    return 1
  fi
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  refresh_homebrew_path
  if command -v brew >/dev/null 2>&1; then
    log "Homebrew installation complete."
    return 0
  fi
  warn "Homebrew installation did not complete successfully."
  return 1
}

powershell_available() {
  command -v powershell.exe >/dev/null 2>&1
}

run_powershell_script() {
  if ! powershell_available; then
    return 127
  fi
  local script="$1"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$script" >"$tmp"
  local win_path="$tmp"
  if command -v wslpath >/dev/null 2>&1; then
    win_path="$(wslpath -w "$tmp")"
  fi
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$win_path"
  local status=$?
  rm -f "$tmp"
  return $status
}

ensure_windows_docker_desktop() {
  if ! is_wsl; then
    return 1
  fi
  if ! powershell_available; then
    warn "powershell.exe not available; cannot automate Docker Desktop installation."
    return 1
  fi

  log "Checking Docker Desktop installation on Windows host"
  local check_script='
& {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    exit 2
  }
  $pkg = winget list --id Docker.DockerDesktop --exact 2>$null
  if ($LASTEXITCODE -eq 0 -and $pkg -match "Docker Desktop") {
    exit 0
  }
  exit 1
}'
  run_powershell_script "$check_script"
  local status=$?
  case "$status" in
    0)
      log "Docker Desktop already installed on Windows."
      return 0
      ;;
    1)
      ;;
    2)
      warn "winget is unavailable; install Docker Desktop manually from https://www.docker.com/products/docker-desktop/."
      return 1
      ;;
    127)
      warn "Unable to execute powershell.exe; install Docker Desktop manually from https://www.docker.com/products/docker-desktop/."
      return 1
      ;;
  esac

  log "Attempting to install Docker Desktop via winget (requires Windows permissions)"
  local install_script='
& {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    exit 2
  }
  winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
  exit $LASTEXITCODE
}'
  run_powershell_script "$install_script"
  local install_status=$?
  case "$install_status" in
    0)
      warn "Docker Desktop installation completed via winget. Launch Docker Desktop once to finish setup, ensure WSL integration is enabled, then re-run this script."
      return 2
      ;;
    3010)
      warn "Docker Desktop installation requires a Windows restart. Reboot, start Docker Desktop, then rerun this script."
      return 2
      ;;
  esac

  warn "winget was unable to install Docker Desktop automatically (exit code $install_status). Falling back to direct download."
  local direct_install_script='
& {
  $uri = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
  $temp = [System.IO.Path]::GetTempPath()
  $installer = Join-Path $temp "DockerDesktopInstaller.exe"
  $proxy = $env:HTTPS_PROXY
  if (-not $proxy) { $proxy = $env:HTTP_PROXY }
  try {
    if ($proxy) {
      Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $installer -Proxy $proxy -ProxyUseDefaultCredentials
    } else {
      Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $installer
    }
  } catch {
    exit 4
  }
  $proc = Start-Process -FilePath $installer -ArgumentList "install","--accept-license","--start-service" -Verb RunAs -PassThru -Wait
  exit $proc.ExitCode
}'
  run_powershell_script "$direct_install_script"
  local direct_status=$?
  case "$direct_status" in
    0)
      warn "Docker Desktop installer launched. Approve the UAC prompt, let the installation finish, enable WSL integration, then re-run this script."
      return 2
      ;;
    3010)
      warn "Docker Desktop installation signaled a reboot requirement. Restart Windows, start Docker Desktop, then rerun this script."
      return 2
      ;;
    4)
      ;;
    *)
      ;;
  esac

  if [[ -n "${DOCKER_DESKTOP_INSTALLER:-}" ]]; then
    log "Attempting Docker Desktop installation from DOCKER_DESKTOP_INSTALLER."
    local env_install_script='
& {
  $installer = $env:DOCKER_DESKTOP_INSTALLER
  if ([string]::IsNullOrWhiteSpace($installer)) { exit 5 }
  if (-not (Test-Path $installer)) { exit 6 }
  $proc = Start-Process -FilePath $installer -ArgumentList "install","--accept-license","--start-service" -Verb RunAs -PassThru -Wait
  exit $proc.ExitCode
}'
    run_powershell_script "$env_install_script"
    local env_status=$?
    case "$env_status" in
      0)
        warn "Docker Desktop installer executed from DOCKER_DESKTOP_INSTALLER. Ensure it completes, then rerun this script."
        return 2
        ;;
      3010)
        warn "Docker Desktop installer from DOCKER_DESKTOP_INSTALLER requested a reboot. Restart Windows and rerun this script."
        return 2
        ;;
      5)
        warn "DOCKER_DESKTOP_INSTALLER environment variable is empty."
        ;;
      6)
        warn "DOCKER_DESKTOP_INSTALLER does not point to an existing file."
        ;;
      *)
        warn "Installer at DOCKER_DESKTOP_INSTALLER exited with code $env_status."
        ;;
    esac
  fi

  warn "Automatic Docker Desktop installation failed. Install it manually from https://www.docker.com/products/docker-desktop/."
  return 1
}

install_docker_via_apt() {
  if [[ ! -f /etc/os-release ]]; then
    return 1
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian)
      ;;
    *)
      return 1
      ;;
  esac

  if is_wsl; then
    return 1
  fi

  local sudo_cmd=""
  if command -v sudo >/dev/null 2>&1 && [[ ${EUID:-0} -ne 0 ]]; then
    sudo_cmd="sudo"
  elif [[ ${EUID:-0} -ne 0 ]]; then
    warn "Cannot install Docker automatically without sudo privileges."
    return 1
  fi

  log "Installing Docker Engine from Docker apt repository"
  local arch
  arch="$(dpkg --print-architecture)"
  local repo_line="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME:-stable} stable"

  if [[ -n "$sudo_cmd" ]]; then
    $sudo_cmd apt-get update -y
    $sudo_cmd apt-get install -y ca-certificates curl gnupg lsb-release
    $sudo_cmd install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | $sudo_cmd gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $sudo_cmd chmod a+r /etc/apt/keyrings/docker.gpg
    printf '%s\n' "$repo_line" | $sudo_cmd tee /etc/apt/sources.list.d/docker.list >/dev/null
    $sudo_cmd apt-get update -y
    $sudo_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    if command -v systemctl >/dev/null 2>&1; then
      $sudo_cmd systemctl enable --now docker || true
    fi
    if getent group docker >/dev/null 2>&1; then
      $sudo_cmd usermod -aG docker "$USER" || true
    fi
  else
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    printf '%s\n' "$repo_line" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now docker || true
    fi
    if getent group docker >/dev/null 2>&1; then
      usermod -aG docker "$USER" || true
    fi
  fi
  return 0
}

provision_toolchain() {
  if [[ -f "$TOOLCHAIN_SCRIPT" ]]; then
    # shellcheck disable=SC1090
    source "$TOOLCHAIN_SCRIPT"
    if ! install_toolchain_main; then
      warn "Toolchain provisioning script reported a failure."
      return 1
    fi
  else
    warn "Toolchain installer not found; skipping automatic CLI provisioning."
  fi
}

ensure_docker_runtime() {
  log "Ensuring Docker runtime is available"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log "Docker daemon reachable."
    return 0
  fi

  if is_wsl; then
    warn "Docker daemon not reachable inside WSL."
    ensure_windows_docker_desktop
    local win_status=$?
    case "$win_status" in
      0)
        warn "Docker Desktop is installed but not running or not integrated with this WSL distro. Launch Docker Desktop in Windows, enable WSL integration for $(uname -n), then re-run this script."
        return 2
        ;;
      2)
        return 2
        ;;
      *)
        return 1
        ;;
    esac
  fi

  if install_docker_via_apt; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      log "Docker Engine installed and ready."
      return 0
    fi
    warn "Docker Engine installed but daemon not yet reachable. Log out and back in (or run 'newgrp docker'), ensure the service is running, then rerun this script."
    return 2
  fi

  warn "Unable to install Docker automatically. Install Docker Engine or Desktop manually."
  return 1
}

verify_docker() {
  log "Verifying: docker info"
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  warn "docker info failed; attempting automated recovery."
  ensure_docker_runtime
  local status=$?
  case "$status" in
    0)
      if docker info >/dev/null 2>&1; then
        log "docker info succeeded after recovery."
        return 0
      fi
      ;;
    2)
      die "Docker is not ready yet. Complete the instructions above (restart Docker Desktop or reboot if requested) and rerun ./scripts/setup-all.sh." 2
      ;;
  esac
  die "Docker verification failed even after recovery. Install or start Docker manually and rerun ./scripts/setup-all.sh."
}

pnpm_recovery_step() {
  local label="$1"
  local attempt="$2"
  case "$attempt" in
    0)
      warn "Running 'pnpm install --frozen-lockfile' as recovery for ${label}."
      pnpm install --frozen-lockfile || return 1
      ;;
    1)
      case "$label" in
        lint)
          warn "Attempting automated lint fixes."
          pnpm lint -- --fix || return 1
          ;;
        web\ tests)
          warn "Ensuring Playwright dependencies are installed."
          pnpm --filter @ai-dev-platform/web exec playwright install --with-deps || return 1
          ;;
        *)
          warn "Running 'pnpm clean' to remove cached build artifacts."
          pnpm clean || return 1
          ;;
      esac
      ;;
    2)
      warn "Performing pnpm store prune and reinstall."
      pnpm store prune >/dev/null 2>&1 || true
      pnpm install --frozen-lockfile --force
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

run_pnpm_check() {
  local cmd="$1"
  local label="$2"
  local max_retries="${POST_CHECK_MAX_RETRIES:-3}"
  local attempt=0
  local log_base="$STATE_DIR/postcheck-${label// /-}"

  while :; do
    local log_file="${log_base}-attempt$((attempt + 1)).log"
    log "Verifying (${label}): ${cmd} (attempt $((attempt + 1)))"
    if eval "$cmd" |& tee "$log_file"; then
      rm -f "$log_file"
      return 0
    fi

    if (( attempt >= max_retries )); then
      break
    fi

    if ! pnpm_recovery_step "$label" "$attempt"; then
      break
    fi
    ((attempt++))
  done

  die "Post-install verification step failed (${label}). Resolve the issue and rerun ./scripts/setup-all.sh."
}

post_checks_impl() {
  if [[ "${SKIP_POST_CHECKS:-0}" == "1" ]]; then
    warn "Skipping post-install verification (SKIP_POST_CHECKS=1)."
    return 0
  fi

  log "Running post-install verification"

  if ! command -v pnpm >/dev/null 2>&1; then
    die "pnpm not found on PATH during verification. Ensure install-toolchain.sh completed successfully."
  fi

  export CI="${CI:-1}"

  verify_docker
  run_pnpm_check "pnpm lint" "lint"
  run_pnpm_check "pnpm type-check" "type-check"
  run_pnpm_check "pnpm --filter @ai-dev-platform/web test -- --runInBand --watch=false --passWithNoTests" "web tests"

  log "Post-install verification complete."
}

run_post_checks() {
  execute_step "post_checks" "Post-install verification" post_checks_impl
}

cd "$ROOT_DIR"

log "AI Dev Platform consolidated setup"
log "Repository root: $ROOT_DIR"

describe_environment
execute_step "system_prereqs" "System prerequisites installation" ensure_system_prereqs

TOOLCHAIN_SCRIPT="$ROOT_DIR/scripts/install-toolchain.sh"
execute_step "toolchain" "Toolchain provisioning" provision_toolchain

if is_step_done "docker_runtime"; then
  log "Skipping Docker runtime preparation (already completed)."
else
  ensure_docker_runtime
  docker_status=$?
  case "$docker_status" in
    0)
      mark_step "docker_runtime"
      ;;
    2)
      die "Docker setup is in progress or awaiting a restart. Complete the instructions above, then rerun ./scripts/setup-all.sh." 2
      ;;
    *)
      die "Docker runtime could not be prepared automatically. Install Docker manually and rerun ./scripts/setup-all.sh."
      ;;
  esac
fi

run_step "Onboarding" "$ONBOARD_SCRIPT" "onboarding"
run_step "Infrastructure bootstrap" "$BOOTSTRAP_SCRIPT" "bootstrap_infra"
run_step "Repository hardening" "$HARDENING_SCRIPT" "github_hardening"

run_post_checks
clear_last_failure

log "All setup steps completed."
log "You can now run 'pnpm --filter @ai-dev-platform/web dev' or open your editor to start developing."
