#!/usr/bin/env bash
# Ensure all required local checks pass, push the current branch, open a pull
# request against main, and enable auto-merge so GitHub handles the protected
# branch update once status checks succeed.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BRANCH="main"

ALLOW_SKIP_TEST_GUARD="${ALLOW_NO_TEST_CHANGES:-0}"

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


ensure_tests_touched() {
  if [[ "$ALLOW_SKIP_TEST_GUARD" == "1" ]]; then
    heading "Skipping test-change guard (ALLOW_NO_TEST_CHANGES set)"
    return 0
  fi

  local base
  if ! base=$(git merge-base HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null); then
    base=$(git merge-base HEAD "$DEFAULT_BRANCH" 2>/dev/null || true)
  fi
  if [[ -z "$base" ]]; then
    heading "Test-change guard: unable to determine merge base; skipping check"
    return 0
  fi

  local changed
  changed=$(git diff --name-only "$base"..HEAD)
  if [[ -z "$changed" ]]; then
    heading "Test-change guard: no changes detected; skipping"
    return 0
  fi

  local code_changed=0
  local tests_changed=0
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if [[ "$file" == apps/web/src/__tests__/* || "$file" == apps/web/tests/e2e/* ]]; then
      tests_changed=1
    fi
    if [[ "$file" == apps/web/src/* && "$file" != apps/web/src/__tests__/* ]]; then
      code_changed=1
    fi
  done <<<"$changed"

  if (( code_changed == 1 && tests_changed == 0 )); then
    echo "Test-change guard: application code changed but no unit/e2e tests were modified." >&2
    echo "Update tests (or set ALLOW_NO_TEST_CHANGES=1 to override) before running push-pr." >&2
    exit 1
  fi
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
  local branch="$1" pr_url
  heading "Creating pull request"
  if gh pr view --head "$branch" --json url >/dev/null 2>&1; then
    pr_url=$(gh pr view --head "$branch" --json url --jq '.url')
    echo "PR already exists for $branch; skipping creation." >&2
  else
    pr_url=$(gh pr create --fill --head "$branch" --base "$DEFAULT_BRANCH" | tail -n1)
  fi
  printf '%s' "$pr_url"
}

annotate_pr() {
  local pr_url="$1"
  heading "Posting automation summary"
  if [[ -z "$pr_url" ]]; then
    echo "PR URL missing; skipping annotation." >&2
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq not available; skipping PR annotation." >&2
    return 0
  fi
  if [[ ! -f "$ROOT_DIR/config/editor-extensions.lock.json" ]]; then
    echo "Lock file missing; skipping PR annotation." >&2
    return 0
  fi
  local versions sync_output body
  versions=$(jq -r '.extensions[] | "- " + .id + " @ " + .version + " (" + .source + ")"' "$ROOT_DIR/config/editor-extensions.lock.json")
  sync_output=$(./scripts/git-sync-check.sh || true)
  body=$'### Automation Summary

#### Editor Extensions
'"$versions"$'

#### Git Sync Status
```
'"$sync_output"$'
```'
  gh pr comment "$pr_url" --body "$body" >/dev/null 2>&1 || echo "Unable to post PR comment." >&2
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
ensure_tests_touched
heading "Verifying editor extensions"
./scripts/verify-editor-extensions.sh --strict
push_branch "$current_branch"
pr_url=$(create_pr "$current_branch")
annotate_pr "$pr_url"
enable_auto_merge
heading "All done. GitHub will merge once required checks pass."
