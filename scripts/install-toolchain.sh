#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NODE_VERSION="${NODE_VERSION:-20.18.0}"
PNPM_VERSION="${PNPM_VERSION:-9.12.0}"
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.9.7}"
GH_VERSION="${GH_VERSION:-2.63.0}"

PKG_MANAGER=""
PKG_UPDATE_PERFORMED=0

heading() {
  printf '\n==> %s\n' "$1"
}

info() {
  printf '%s\n' "$1"
}

warn() {
  printf 'warning: %s\n' "$1" >&2
}

die() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

ensure_local_bin() {
  local local_bin="$HOME/.local/bin"
  mkdir -p "$local_bin"
  case ":$PATH:" in
    *":$local_bin:"*) ;;
    *) export PATH="$local_bin:$PATH" ;;
  esac
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    return 0
  fi
  if command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    return 0
  fi
  if command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
    return 0
  fi
  if command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    PKG_MANAGER="brew"
    return 0
  fi
  PKG_MANAGER=""
  return 1
}

package_install() {
  local package="$1"
  if [[ -z "$PKG_MANAGER" ]]; then
    return 1
  fi

  local sudo_cmd=""
  if command -v sudo >/dev/null 2>&1 && [[ ${EUID:-0} -ne 0 ]]; then
    sudo_cmd="sudo"
  fi

  case "$PKG_MANAGER" in
    apt)
      if (( PKG_UPDATE_PERFORMED == 0 )); then
        if [[ -n "$sudo_cmd" ]]; then
          $sudo_cmd apt-get update -y
        else
          apt-get update -y
        fi
        PKG_UPDATE_PERFORMED=1
      fi
      if [[ -n "$sudo_cmd" ]]; then
        $sudo_cmd apt-get install -y "$package"
      else
        apt-get install -y "$package"
      fi
      ;;
    dnf)
      if [[ -n "$sudo_cmd" ]]; then
        $sudo_cmd dnf install -y "$package"
      else
        dnf install -y "$package"
      fi
      ;;
    yum)
      if [[ -n "$sudo_cmd" ]]; then
        $sudo_cmd yum install -y "$package"
      else
        yum install -y "$package"
      fi
      ;;
    pacman)
      if [[ -n "$sudo_cmd" ]]; then
        $sudo_cmd pacman -Sy --noconfirm "$package"
      else
        pacman -Sy --noconfirm "$package"
      fi
      ;;
    zypper)
      if [[ -n "$sudo_cmd" ]]; then
        $sudo_cmd zypper install -y "$package"
      else
        zypper install -y "$package"
      fi
      ;;
    brew)
      brew install "$package"
      ;;
    *)
      return 1
      ;;
  esac
}

download_file() {
  local url="$1"
  local destination="$2"
  curl -fsSL "$url" -o "$destination"
}

ensure_curl() {
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi
  heading "Installing curl"
  if package_install curl; then
    return 0
  fi
  die "curl is required but could not be installed automatically."
}

ensure_unzip() {
  if command -v unzip >/dev/null 2>&1; then
    return 0
  fi
  heading "Installing unzip"
  if package_install unzip; then
    return 0
  fi
  warn "unzip not available; attempting to fall back to tar when possible."
  return 0
}

ensure_python() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  heading "Installing Python 3"
  if package_install python3; then
    return 0
  fi
  warn "Python 3 is not available automatically. Some tooling may fail."
  return 1
}

node_major_version() {
  local raw="$1"
  raw="${raw#v}"
  printf '%s' "${raw%%.*}"
}

install_node() {
  heading "Installing Node.js ${NODE_VERSION}"

  local uname_s uname_m os arch tarball url tmp_dir node_dir
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"

  case "$uname_s" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *)
      die "Unsupported operating system for Node.js install: $uname_s"
      return 1
      ;;
  esac

  case "$uname_m" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)
      die "Unsupported architecture for Node.js install: $uname_m"
      return 1
      ;;
  esac

  tarball="node-v${NODE_VERSION}-${os}-${arch}.tar.xz"
  url="https://nodejs.org/dist/v${NODE_VERSION}/${tarball}"
  tmp_dir="$(mktemp -d)"

  download_file "$url" "$tmp_dir/$tarball"
  tar -xJf "$tmp_dir/$tarball" -C "$tmp_dir"

  node_dir="$HOME/.local/node-v${NODE_VERSION}-${os}-${arch}"
  rm -rf "$node_dir"
  mv "$tmp_dir/node-v${NODE_VERSION}-${os}-${arch}" "$node_dir"

  ln -sf "$node_dir/bin/node" "$HOME/.local/bin/node"
  ln -sf "$node_dir/bin/npm" "$HOME/.local/bin/npm"
  ln -sf "$node_dir/bin/npx" "$HOME/.local/bin/npx"
  ln -sf "$node_dir/bin/corepack" "$HOME/.local/bin/corepack"

  rm -rf "$tmp_dir"
}

ensure_node() {
  if command -v node >/dev/null 2>&1; then
    local version major
    version="$(node -v || true)"
    major="$(node_major_version "$version")"
    if [[ -n "$major" ]] && (( major >= 20 )); then
      info "Node.js ${version} already installed."
      return 0
    fi
    warn "Detected Node.js ${version}; upgrading to ${NODE_VERSION}."
  fi
  install_node
}

ensure_pnpm() {
  if command -v pnpm >/dev/null 2>&1; then
    local major
    major="$(pnpm --version 2>/dev/null | cut -d. -f1 || echo "")"
    if [[ -n "$major" ]] && (( major >= 9 )); then
      info "pnpm $(pnpm --version) already installed."
      return 0
    fi
    warn "Detected pnpm $(pnpm --version 2>/dev/null); upgrading to ${PNPM_VERSION}."
  fi

  if ! command -v corepack >/dev/null 2>&1; then
    ensure_node
  fi

  heading "Installing pnpm ${PNPM_VERSION}"
  corepack enable >/dev/null 2>&1 || true
  corepack prepare "pnpm@${PNPM_VERSION}" --activate

  local pnpm_target
  pnpm_target="$(corepack which pnpm 2>/dev/null || true)"
  if [[ -n "$pnpm_target" && -x "$pnpm_target" ]]; then
    ln -sf "$pnpm_target" "$HOME/.local/bin/pnpm"
  fi

  if ! command -v pnpm >/dev/null 2>&1; then
    die "pnpm installation failed."
    return 1
  fi
}

fetch_latest_gcloud_version() {
  local python_bin version
  python_bin="$(command -v python3 || command -v python || true)"
  if [[ -z "$python_bin" ]]; then
    echo ""
    return 1
  fi
  version="$($python_bin - <<'PY'
import json
import sys
import urllib.request

try:
    with urllib.request.urlopen("https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json") as fp:
        data = json.load(fp)
    print(data.get("version", ""))
except Exception:
    sys.exit(1)
PY
  2>/dev/null || true)"
  echo "$version"
}

install_gcloud() {
  heading "Installing Google Cloud CLI"
  local version os arch tarball url tmp_dir sdk_dir

  version="$(fetch_latest_gcloud_version)"
  if [[ -z "$version" ]]; then
    version="477.0.0"
    warn "Unable to detect latest gcloud version automatically; defaulting to ${version}."
  fi

  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *)
      die "Unsupported operating system for Google Cloud CLI."
      return 1
      ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="arm" ;;
    *)
      die "Unsupported architecture for Google Cloud CLI."
      return 1
      ;;
  esac

  tarball="google-cloud-cli-${version}-${os}-${arch}.tar.gz"
  url="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${tarball}"
  tmp_dir="$(mktemp -d)"

  download_file "$url" "$tmp_dir/$tarball"
  tar -xzf "$tmp_dir/$tarball" -C "$tmp_dir"

  sdk_dir="$HOME/.local/google-cloud-sdk"
  rm -rf "$sdk_dir"
  mv "$tmp_dir/google-cloud-sdk" "$sdk_dir"

  CLOUDSDK_CORE_DISABLE_PROMPTS=1 \
  CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK=1 \
    "$sdk_dir/install.sh" --usage-reporting=false --path-update=false --bash-completion=false >/dev/null

  ln -sf "$sdk_dir/bin/gcloud" "$HOME/.local/bin/gcloud"
  ln -sf "$sdk_dir/bin/gsutil" "$HOME/.local/bin/gsutil"
  ln -sf "$sdk_dir/bin/bq" "$HOME/.local/bin/bq"

  rm -rf "$tmp_dir"
}

ensure_gcloud() {
  if command -v gcloud >/dev/null 2>&1; then
    info "Google Cloud CLI already installed."
    return 0
  fi
  install_gcloud
  if ! command -v gcloud >/dev/null 2>&1; then
    die "Google Cloud CLI installation failed."
    return 1
  fi
}

install_terraform() {
  heading "Installing Terraform ${TERRAFORM_VERSION}"

  local os arch tmp_dir url

  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *)
      die "Unsupported operating system for Terraform."
      return 1
      ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)
      die "Unsupported architecture for Terraform."
      return 1
      ;;
  esac

  url="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${os}_${arch}.zip"
  tmp_dir="$(mktemp -d)"

  download_file "$url" "$tmp_dir/terraform.zip"
  if command -v unzip >/dev/null 2>&1; then
    unzip -o "$tmp_dir/terraform.zip" -d "$tmp_dir" >/dev/null
  else
    warn "unzip not available; attempting to use Python zipfile module for Terraform."
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$tmp_dir/terraform.zip" "$tmp_dir" <<'PY'
import sys
import zipfile

archive = sys.argv[1]
destination = sys.argv[2]
with zipfile.ZipFile(archive, 'r') as zf:
    zf.extractall(destination)
PY
    else
      rm -rf "$tmp_dir"
      die "Unable to extract Terraform archive (missing unzip and python3)."
    fi
  fi

  chmod +x "$tmp_dir/terraform"
  mv "$tmp_dir/terraform" "$HOME/.local/bin/terraform"

  rm -rf "$tmp_dir"
}

ensure_terraform() {
  if command -v terraform >/dev/null 2>&1; then
    info "Terraform $(terraform version | head -n 1) already installed."
    return 0
  fi
  install_terraform
  if ! command -v terraform >/dev/null 2>&1; then
    die "Terraform installation failed."
    return 1
  fi
}

install_gh() {
  heading "Installing GitHub CLI ${GH_VERSION}"

  local os arch tmp_dir tarball url
  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="macOS" ;;
    *)
      die "Unsupported operating system for GitHub CLI."
      return 1
      ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)
      die "Unsupported architecture for GitHub CLI."
      return 1
      ;;
  esac

  tarball="gh_${GH_VERSION}_${os}_${arch}.tar.gz"
  url="https://github.com/cli/cli/releases/download/v${GH_VERSION}/${tarball}"
  tmp_dir="$(mktemp -d)"

  download_file "$url" "$tmp_dir/$tarball"
  tar -xzf "$tmp_dir/$tarball" -C "$tmp_dir"
  chmod +x "$tmp_dir/gh_${GH_VERSION}_${os}_${arch}/bin/gh"
  mv "$tmp_dir/gh_${GH_VERSION}_${os}_${arch}/bin/gh" "$HOME/.local/bin/gh"

  rm -rf "$tmp_dir"
}

ensure_gh() {
  if command -v gh >/dev/null 2>&1; then
    info "GitHub CLI $(gh --version | head -n 1) already installed."
    return 0
  fi
  install_gh
  if ! command -v gh >/dev/null 2>&1; then
    die "GitHub CLI installation failed."
    return 1
  fi
}

install_toolchain_main() {
  ensure_local_bin
  detect_package_manager || true
  if ! ensure_curl; then
    die "curl is required."
    return 1
  fi
  ensure_unzip || true
  ensure_python || true
  if ! ensure_node; then
    return 1
  fi
  if ! ensure_pnpm; then
    return 1
  fi
  if ! ensure_gcloud; then
    return 1
  fi
  if ! ensure_terraform; then
    return 1
  fi
  if ! ensure_gh; then
    return 1
  fi
  info "All prerequisite CLI tooling is ready."
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install_toolchain_main
fi
