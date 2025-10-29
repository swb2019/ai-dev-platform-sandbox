#!/usr/bin/env bash
set -euo pipefail

# Installs supply-chain tooling (Trivy, Grype, Syft, Cosign) using pinned versions
# and checksum verification. Intended for GitHub runners and local automation.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET_BIN_DIR="${TARGET_BIN_DIR:-/usr/local/bin}"

TRIVY_VERSION="${TRIVY_VERSION:-0.55.2}"
GRYPE_VERSION="${GRYPE_VERSION:-0.79.3}"
SYFT_VERSION="${SYFT_VERSION:-1.33.0}"
COSIGN_VERSION="${COSIGN_VERSION:-2.4.0}"

need_sudo() {
  [[ -w "$TARGET_BIN_DIR" ]] && [[ -d "$TARGET_BIN_DIR" ]] && return 1
  return 0
}

run_install() {
  if need_sudo; then
    sudo "$@"
  else
    "$@"
  fi
}

ensure_requirements() {
  local deps=(curl sha256sum tar)
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      echo "Required command '$dep' is not available." >&2
      exit 1
    fi
  done
}

already_installed() {
  local bin="$1" expected="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    return 1
  fi
  local current
  if ! current="$("$bin" --version 2>/dev/null)"; then
    return 1
  fi
  [[ "$current" =~ $expected ]]
}

install_tar_binary() {
  local name="$1" version="$2" url="$3" checksum_url="$4" binary_name="$5"

  if already_installed "$binary_name" "$version"; then
    echo "$name $version already installed; skipping."
    return 0
  fi

  local workdir
  workdir="$(mktemp -d)"

  local archive_name="${url##*/}"
  local archive="$workdir/${archive_name}"
  local checksums="$workdir/checksums.txt"

  curl -fsSL -o "$archive" "$url"
  curl -fsSL -o "$checksums" "$checksum_url"

  if ! grep "$archive_name" "$checksums" >"$workdir/selected.checksum"; then
    echo "Checksum for $archive_name not found in $checksum_url" >&2
    exit 1
  fi

  (cd "$workdir" && sha256sum --check selected.checksum)

  tar -xzf "$archive" -C "$workdir"
  local binary_path
  binary_path="$(find "$workdir" -type f -name "$binary_name" -perm -u+x | head -n 1)"
  if [[ -z "$binary_path" ]]; then
    echo "Binary $binary_name not found in archive for $name." >&2
    exit 1
  fi

  run_install install -m 0755 "$binary_path" "$TARGET_BIN_DIR/$binary_name"
  echo "Installed $name $version to $TARGET_BIN_DIR/$binary_name"
  rm -rf "$workdir"
}

install_raw_binary() {
  local name="$1" version="$2" url="$3" checksum_url="$4" target_name="$5"

  if already_installed "$target_name" "$version"; then
    echo "$name $version already installed; skipping."
    return 0
  fi

  local workdir
  workdir="$(mktemp -d)"

  local asset_name="${url##*/}"
  local checksum_asset="${checksum_url##*/}"
  local binary="$workdir/$asset_name"
  local checksum_file="$workdir/$checksum_asset"

  curl -fsSL -o "$binary" "$url"
  curl -fsSL -o "$checksum_file" "$checksum_url"

  local checksum_entry
  checksum_entry="$(grep -E "^[0-9a-fA-F]+\s+$asset_name$" "$checksum_file" || true)"
  if [[ -z "$checksum_entry" ]]; then
    echo "Checksum entry for $asset_name not found in $checksum_url" >&2
    exit 1
  fi

  printf '%s\n' "$checksum_entry" >"$workdir/selected.checksum"
  (cd "$workdir" && sha256sum --check selected.checksum)

  chmod +x "$binary"
  run_install install -m 0755 "$binary" "$TARGET_BIN_DIR/$target_name"
  echo "Installed $name $version to $TARGET_BIN_DIR/$target_name"
  rm -rf "$workdir"
}

main() {
  ensure_requirements
  run_install mkdir -p "$TARGET_BIN_DIR"

  install_tar_binary "Trivy" "$TRIVY_VERSION" \
    "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
    "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_checksums.txt" \
    "trivy"

  install_tar_binary "Grype" "$GRYPE_VERSION" \
    "https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_linux_amd64.tar.gz" \
    "https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_checksums.txt" \
    "grype"

  install_tar_binary "Syft" "$SYFT_VERSION" \
    "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_amd64.tar.gz" \
    "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_checksums.txt" \
    "syft"

  install_raw_binary "Cosign" "$COSIGN_VERSION" \
    "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64" \
    "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign_checksums.txt" \
    "cosign"
}

main "$@"
