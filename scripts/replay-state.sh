#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: ./scripts/replay-state.sh <commit>" >&2
  exit 1
fi

COMMIT="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[replay] checking out $COMMIT"
 git fetch --all --tags >/dev/null 2>&1 || true
 git checkout "$COMMIT"

echo "[replay] installing dependencies"
pnpm install --frozen-lockfile

echo "[replay] updating editor extensions"
./scripts/update-editor-extensions.sh

echo "[replay] verifying editor extensions"
./scripts/verify-editor-extensions.sh --strict

echo "[replay] running test suite"
./scripts/test-suite.sh

cat <<INFO
Replay complete. Repository is now on commit $COMMIT with dependencies, extensions, and tests validated.
INFO
