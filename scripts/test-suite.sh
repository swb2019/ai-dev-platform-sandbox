#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[test-suite] pnpm lint"
pnpm lint

echo "[test-suite] pnpm type-check"
pnpm type-check

echo "[test-suite] pnpm --filter @ai-dev-platform/web test"
pnpm --filter @ai-dev-platform/web test

echo "[test-suite] pnpm --filter @ai-dev-platform/web test:e2e"
pnpm --filter @ai-dev-platform/web test:e2e

echo "[test-suite] all checks passed"
