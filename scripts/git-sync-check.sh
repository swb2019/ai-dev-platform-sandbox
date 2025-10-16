#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/git-sync-check.sh

Fetches the remote tracking branch and reports whether the current branch is ahead or behind.
Exits with 0 when the local branch is synchronized, or 1 when manual action is required.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: this command must be run inside a Git repository." >&2
  exit 2
fi

REMOTE="${GIT_SYNC_REMOTE:-origin}"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

if [[ "$CURRENT_BRANCH" == "HEAD" ]]; then
  echo "Detached HEAD state detected. Sync check skipped." >&2
  exit 2
fi

# Fetch latest references quietly but keep stderr visible if the command fails.
if ! git fetch --prune --tags "$REMOTE" >/dev/null 2>&1; then
  echo "git fetch from $REMOTE failed; resolve the issue and retry." >&2
  exit 2
fi

STATUS_LINE="$(git status -sb | head -n 1)"
echo "$STATUS_LINE"

ahead=0
behind=0
if [[ "$STATUS_LINE" =~ \[ahead\ ([0-9]+) ]]; then
  ahead=${BASH_REMATCH[1]}
fi
if [[ "$STATUS_LINE" =~ \[behind\ ([0-9]+) ]]; then
  behind=${BASH_REMATCH[1]}
fi

if (( ahead == 0 && behind == 0 )); then
  echo "✓ Local branch is up to date with $REMOTE/$CURRENT_BRANCH."
  if [[ -n "${SYNC_OUTPUT_TO:-}" ]]; then
    {
      echo "$STATUS_LINE"
      echo "ahead=0"
      echo "behind=0"
    } > "$SYNC_OUTPUT_TO"
  fi
  exit 0
fi

echo "⚠ Repository is out of sync with $REMOTE/$CURRENT_BRANCH." >&2
if [[ -n "${SYNC_OUTPUT_TO:-}" ]]; then
  {
    echo "$STATUS_LINE"
    (( ahead > 0 )) && echo "ahead=$ahead"
    (( behind > 0 )) && echo "behind=$behind"
  } > "$SYNC_OUTPUT_TO"
fi
if (( ahead > 0 )); then
  echo "  - Local branch is ahead by $ahead commit(s); push or reset as appropriate." >&2
fi
if (( behind > 0 )); then
  echo "  - Local branch is behind by $behind commit(s); pull or rebase to incorporate remote changes." >&2
fi
exit 1
