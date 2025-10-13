#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/monitor-pr.sh [--head <branch>] [--interval <seconds>]

Poll GitHub for the status of the PR associated with the specified branch (default: current branch).
The script waits until the PR is merged, exits 0 on success, or exits non-zero if the PR closes without merging.
USAGE
}

branch=""
interval=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --head)
      branch="$2"
      shift 2
      ;;
    --interval)
      interval="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$branch" ]]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
fi

if [[ "$branch" == "HEAD" ]]; then
  echo "Cannot monitor a detached HEAD." >&2
  exit 2
fi

fetch_pr_json() {
  gh pr view --head "$branch" --json number,state,mergeableState,url 2>/dev/null || return 1
}

if ! pr_json=$(fetch_pr_json); then
  echo "No PR found for branch $branch. Ensure ./scripts/push-pr.sh has created one." >&2
  exit 2
fi

number=$(echo "$pr_json" | jq -r '.number')
url=$(echo "$pr_json" | jq -r '.url')

echo "Monitoring PR #$number ($url) every ${interval}s..."

while true; do
  if ! pr_json=$(fetch_pr_json); then
    echo "PR lookup failed; retrying in ${interval}s." >&2
    sleep "$interval"
    continue
  fi
  state=$(echo "$pr_json" | jq -r '.state')
  mergeable=$(echo "$pr_json" | jq -r '.mergeableState')
  timestamp=$(date --iso-8601=seconds)
  echo "[$timestamp] state=$state mergeableState=$mergeable"
  case "$state" in
    MERGED)
      echo "PR merged successfully." >&2
      exit 0
      ;;
    OPEN)
      sleep "$interval"
      ;;
    CLOSED)
      echo "PR closed without merge. Investigate manually." >&2
      exit 1
      ;;
    *)
      echo "Unexpected PR state: $state" >&2
      sleep "$interval"
      ;;
  esac
done
