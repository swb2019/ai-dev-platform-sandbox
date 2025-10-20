#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
POLICY_ROOT="${REPO_ROOT}/deploy/policies/gatekeeper"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required to apply Gatekeeper policies." >&2
  exit 1
fi

if [[ ! -d "${POLICY_ROOT}" ]]; then
  echo "Policy directory not found at ${POLICY_ROOT}" >&2
  exit 1
fi

echo "[gatekeeper] Applying constraint templates"
kubectl apply -f "${POLICY_ROOT}/templates"

echo "[gatekeeper] Applying constraints"
kubectl apply -f "${POLICY_ROOT}/constraints"

echo "[gatekeeper] Policies applied successfully."
