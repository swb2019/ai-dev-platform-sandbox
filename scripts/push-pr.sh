#!/usr/bin/env bash
# Ensure all required local checks pass, push the current branch, open a pull
# request against main, and enable auto-merge so GitHub handles the protected
# branch update once status checks succeed.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BRANCH="main"

heading() {
  printf '\n==> %s\n' "$1" >&2
}

require_clean_worktree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is dirty. Commit or stash changes before running this script." >&2
    exit 1
  fi
}

ensure_branch() {
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD)
  if [[ "$branch" == "$DEFAULT_BRANCH" ]]; then
    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    branch="auto/${timestamp}"
    heading "Creating feature branch $branch"
    git checkout -b "$branch"
  fi
  printf '%s' "$branch"
}

run_checks() {
  heading "Running lint"
  pnpm lint
  heading "Running type-check"
  pnpm type-check
  heading "Running unit tests"
  pnpm --filter @ai-dev-platform/web test
  heading "Running Playwright e2e"
  pnpm --filter @ai-dev-platform/web test:e2e
}

push_branch() {
  local branch="$1"
  heading "Pushing branch $branch"
  if ! git push -u origin "$branch"; then
    echo "Initial push failed; retrying with --force-with-lease." >&2
    git push --force-with-lease -u origin "$branch"
  fi
}

create_pr() {
  local branch="$1"
  heading "Creating pull request"
  if gh pr view --head "$branch" >/dev/null 2>&1; then
    echo "PR already exists for $branch; skipping creation."
  else
    gh pr create --fill --head "$branch" --base "$DEFAULT_BRANCH"
  fi
}

enable_auto_merge() {
  heading "Enabling auto-merge"
  if ! gh pr merge --auto --squash --delete-branch; then
    echo "Auto-merge could not be enabled. Enable it in the repository settings or merge manually once checks pass." >&2
  fi
}

cd "$ROOT_DIR"
require_clean_worktree
current_branch=$(ensure_branch)
run_checks
push_branch "$current_branch"
create_pr "$current_branch"
enable_auto_merge
heading "All done. GitHub will merge once required checks pass."
