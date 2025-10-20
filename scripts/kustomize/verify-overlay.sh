#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  cat <<'USAGE'
Usage: scripts/kustomize/verify-overlay.sh <overlay-path> [expected-image-repo]

Validates that the supplied Kustomize overlay pins an immutable image digest and
does not contain placeholder metadata. Optionally asserts the resolved image
repository matches the expected value.
USAGE
  exit 1
fi

OVERLAY_DIR="$1"
EXPECTED_REPO="${2:-}"
KUSTOMIZATION_FILE="${OVERLAY_DIR%/}/kustomization.yaml"
SERVICEACCOUNT_PATCH="${OVERLAY_DIR%/}/patches/serviceaccount-annotation.yaml"

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required for overlay verification but is not available on PATH." >&2
  exit 1
fi

if [[ ! -f "$KUSTOMIZATION_FILE" ]]; then
  echo "Kustomization file not found: $KUSTOMIZATION_FILE" >&2
  exit 1
fi

IMAGE_NEW_NAME="$(yq -e '.images[0].newName' "$KUSTOMIZATION_FILE" 2>/dev/null || true)"
IMAGE_DIGEST="$(yq -e '.images[0].digest' "$KUSTOMIZATION_FILE" 2>/dev/null || true)"

if [[ -z "$IMAGE_NEW_NAME" || "$IMAGE_NEW_NAME" == "null" ]]; then
  echo "Overlay $OVERLAY_DIR does not define images[0].newName." >&2
  exit 1
fi

if [[ "$IMAGE_NEW_NAME" == *"PLACEHOLDER"* ]]; then
  echo "Overlay $OVERLAY_DIR still references a placeholder image name: $IMAGE_NEW_NAME" >&2
  exit 1
fi

if [[ -z "$IMAGE_DIGEST" || "$IMAGE_DIGEST" == "null" ]]; then
  echo "Overlay $OVERLAY_DIR does not define images[0].digest." >&2
  exit 1
fi

if [[ "$IMAGE_DIGEST" == *"PLACEHOLDER"* ]]; then
  echo "Overlay $OVERLAY_DIR still contains a placeholder digest value." >&2
  exit 1
fi

if [[ ! "$IMAGE_DIGEST" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
  echo "Overlay $OVERLAY_DIR digest is not a valid sha256 reference: $IMAGE_DIGEST" >&2
  exit 1
fi

if [[ -n "$EXPECTED_REPO" && "$IMAGE_NEW_NAME" != "$EXPECTED_REPO" ]]; then
  echo "Overlay $OVERLAY_DIR image newName '$IMAGE_NEW_NAME' does not match expected '$EXPECTED_REPO'." >&2
  exit 1
fi

if [[ -f "$SERVICEACCOUNT_PATCH" ]]; then
  SERVICEACCOUNT_GSA="$(yq -e '.metadata.annotations."iam.gke.io/gcp-service-account"' "$SERVICEACCOUNT_PATCH" 2>/dev/null || true)"
  if [[ -z "$SERVICEACCOUNT_GSA" || "$SERVICEACCOUNT_GSA" == "null" ]]; then
    echo "ServiceAccount patch in $OVERLAY_DIR does not define the Workload Identity annotation." >&2
    exit 1
  fi
  if [[ "$SERVICEACCOUNT_GSA" == *"PLACEHOLDER"* ]]; then
    echo "ServiceAccount patch in $OVERLAY_DIR still contains a placeholder GSA annotation." >&2
    exit 1
  fi
fi

printf 'Overlay %s pins image %s@%s and passes verification.\n' "$OVERLAY_DIR" "$IMAGE_NEW_NAME" "$IMAGE_DIGEST"
