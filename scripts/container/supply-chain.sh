#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION="${1:-}"

if [[ -z "$ACTION" ]]; then
  cat <<'USAGE'
Usage: scripts/container/supply-chain.sh <action>

Actions:
  build    Build the web application container image.
  scan     Run Trivy and Grype vulnerability scans against the image.
  sbom     Generate a CycloneDX SBOM using Syft.
  sign     Sign the image and SBOM with Cosign using keyless (OIDC) workflow.

Environment variables:
  IMAGE_REPO   Target image repository (default: ghcr.io/<owner>/web or local/web).
  IMAGE_TAG    Image tag to operate on (default: dev).
  DOCKERFILE   Dockerfile path (default: apps/web/Dockerfile).
  BUILD_CONTEXT Docker build context (default: project root).
  SBOM_OUTPUT  SBOM output path (default: artifacts/sbom/web-cyclonedx.json).
USAGE
  exit 1
fi

IMAGE_REPO_DEFAULT="local/ai-dev-platform-web"
if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
  IMAGE_REPO_DEFAULT="ghcr.io/${GITHUB_REPOSITORY}/web"
fi
IMAGE_REPO="${IMAGE_REPO:-$IMAGE_REPO_DEFAULT}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
IMAGE_REF="${IMAGE_REPO}:${IMAGE_TAG}"
DOCKERFILE="${DOCKERFILE:-apps/web/Dockerfile}"
BUILD_CONTEXT="${BUILD_CONTEXT:-${ROOT_DIR}}"
SBOM_OUTPUT="${SBOM_OUTPUT:-${ROOT_DIR}/artifacts/sbom/web-cyclonedx.json}"

TRIVY_IGNORE_FILE="${TRIVY_IGNORE_FILE:-${ROOT_DIR}/.trivyignore}"
GRYPE_CONFIG="${GRYPE_CONFIG:-${ROOT_DIR}/.grype.yaml}"
TRIVY_CACHE_DIR="${TRIVY_CACHE_DIR:-${ROOT_DIR}/.cache/trivy}"
GRYPE_CACHE_DIR="${GRYPE_CACHE_DIR:-${ROOT_DIR}/.cache/grype}"

mkdir -p "$(dirname "$SBOM_OUTPUT")"
mkdir -p "$TRIVY_CACHE_DIR" "$GRYPE_CACHE_DIR"

require_cmd() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Error: required command '$bin' is not available" >&2
    exit 1
  fi
}

ensure_image() {
  if ! docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
    echo "Docker image '$IMAGE_REF' not found. Build it first (action: build)." >&2
    exit 1
  fi
}

resolve_dir_path() {
  local target="$1"
  if [[ -d "$target" ]]; then
    (cd "$target" && pwd)
    return
  fi
  if [[ -d "${ROOT_DIR}/$target" ]]; then
    (cd "${ROOT_DIR}/$target" && pwd)
    return
  fi
  echo "Error: directory '$target' not found (relative to '${ROOT_DIR}')" >&2
  exit 1
}

resolve_file_path() {
  local target="$1"
  if [[ -f "$target" ]]; then
    (cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd)" "$(basename "$target")")
    return
  fi
  if [[ -f "${ROOT_DIR}/$target" ]]; then
    (cd "$(dirname "${ROOT_DIR}/$target")" && printf '%s/%s\n' "$(pwd)" "$(basename "$target")")
    return
  fi
  echo "Error: file '$target' not found (relative to '${ROOT_DIR}')" >&2
  exit 1
}

cmd_build() {
  require_cmd docker
  local context_path
  context_path="$(resolve_dir_path "$BUILD_CONTEXT")"
  local dockerfile_path
  dockerfile_path="$(resolve_file_path "$DOCKERFILE")"

  local dockerfile_arg="$dockerfile_path"
  if [[ "$dockerfile_path" == "$context_path"/* ]]; then
    dockerfile_arg="${dockerfile_path#${context_path}/}"
  fi

  echo "Building image $IMAGE_REF using $dockerfile_arg"
  (
    cd "$context_path"
    docker build \
      --file "$dockerfile_arg" \
      --tag "$IMAGE_REF" \
      .
  )
}

cmd_scan() {
  require_cmd docker
  require_cmd trivy
  require_cmd grype
  ensure_image

  echo "Running Trivy scan (HIGH,CRITICAL) on $IMAGE_REF"
  local trivy_args=("image" "--quiet" "--exit-code" "1" "--severity" "HIGH,CRITICAL" "--cache-dir" "$TRIVY_CACHE_DIR")
  if [[ -f "$TRIVY_IGNORE_FILE" ]]; then
    trivy_args+=("--ignorefile" "$TRIVY_IGNORE_FILE")
  fi
  trivy_args+=("$IMAGE_REF")
  trivy "${trivy_args[@]}"

  echo "Running Grype scan (fail on HIGH) on $IMAGE_REF"
  local grype_args=("--fail-on" "High" "--scope" "Squashed")
  if [[ -f "$GRYPE_CONFIG" ]]; then
    grype_args=("--config" "$GRYPE_CONFIG" "--fail-on" "High" "--scope" "Squashed")
  fi
  GRYPE_DB_CACHE_DIR="$GRYPE_CACHE_DIR" grype "${grype_args[@]}" "$IMAGE_REF"
}

cmd_sbom() {
  require_cmd docker
  require_cmd syft
  ensure_image

  echo "Generating CycloneDX SBOM at $SBOM_OUTPUT"
  syft "$IMAGE_REF" -o cyclonedx-json >"$SBOM_OUTPUT"
}

cmd_sign() {
  require_cmd cosign
  ensure_image
  if [[ ! -s "$SBOM_OUTPUT" ]]; then
    echo "SBOM file '$SBOM_OUTPUT' not found. Run the sbom action first." >&2
    exit 1
  fi

  echo "Signing image $IMAGE_REF with Cosign (keyless)"
  COSIGN_YES="${COSIGN_YES:-true}" COSIGN_EXPERIMENTAL=1 cosign sign "$IMAGE_REF"

  echo "Attesting image $IMAGE_REF with SBOM predicate"
  COSIGN_YES="${COSIGN_YES:-true}" COSIGN_EXPERIMENTAL=1 cosign attest \
    --type cyclonedx \
    --predicate "$SBOM_OUTPUT" \
    "$IMAGE_REF"
}

case "$ACTION" in
  build)
    cmd_build
    ;;
  scan)
    cmd_scan
    ;;
  sbom)
    cmd_sbom
    ;;
  sign)
    cmd_sign
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    exit 1
    ;;
 esac
