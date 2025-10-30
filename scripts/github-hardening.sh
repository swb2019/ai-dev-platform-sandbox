#!/usr/bin/env bash
#
# GitHub repository hardening helper.
#
# Defaults are loaded from scripts/github-hardening.conf (or the path provided
# via GITHUB_HARDENING_CONFIG). Flags can still override individual values when
# needed, but the goal is to make the workflow fully unattended.

set -euo pipefail

OWNER=""
REPO=""
PROTECTED_BRANCH="main"
REQUIRED_CHECKS_DEFAULT="ci,deploy-staging,e2e-validation"
REQUIRED_CHECK_CONTEXTS=()
REMOVE_PROD_ENV=true
STAGING_WAIT_MINUTES=0
PRODUCTION_WAIT_MINUTES=30
STAGING_REVIEWERS=()
PRODUCTION_REVIEWERS=()
CONFIG_FILE="scripts/github-hardening.conf"
CODEQL_WORKFLOW_PATH=".github/workflows/codeql.yml"

ENABLE_PR_REVIEWS=true
REQUIRED_APPROVING_REVIEWS=2
REQUIRE_CODE_OWNER_REVIEWS=true
DISMISS_STALE_REVIEWS=true
REQUIRE_CONVERSATION_RESOLUTION=true

REQUIRE_SIGNED_COMMITS=true

trim() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

to_bool() {
  local value="${1:-false}"
  case "${value,,}" in
    true|1|yes|on) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

infer_repo_from_git() {
  local remote
  remote=$(git config --get remote.origin.url 2>/dev/null || true)
  [[ -n "$remote" ]] || return 1

  case "$remote" in
    git@github.com:*)
      remote=${remote#git@github.com:}
      ;;
    https://github.com/*)
      remote=${remote#https://github.com/}
      ;;
    git://github.com/*)
      remote=${remote#git://github.com/}
      ;;
    ssh://git@github.com/*)
      remote=${remote#ssh://git@github.com/}
      ;;
    *)
      return 1
      ;;
  esac

  remote=${remote%.git}
  OWNER=${remote%%/*}
  REPO=${remote#*/}
  [[ -n "$OWNER" && -n "$REPO" ]] || return 1
  return 0
}

load_config_if_present() {
  local path="${GITHUB_HARDENING_CONFIG:-$CONFIG_FILE}"
  if [[ -f "$path" ]]; then
    # shellcheck disable=SC1090
    source "$path"
  fi
}
heading() {
  printf '\n==> %s\n' "$1"
}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PENDING_NOTICE_FILE="$REPO_ROOT/tmp/github-hardening.pending"

write_pending_notice() {
  mkdir -p "$(dirname "$PENDING_NOTICE_FILE")"
  cat >"$PENDING_NOTICE_FILE" <<EOF
GitHub repository hardening requires GitHub CLI authentication.

Next steps for ${OWNER}/${REPO}:
  1. Run: gh auth login --hostname github.com --git-protocol https --web --scopes "repo,workflow,admin:org"
     and complete the browser flow when prompted.
  2. Re-run ./scripts/github-hardening.sh once authentication completes.

This step configures branch protections, environments, and security features for the repository.
EOF
}

clear_pending_notice() {
  rm -f "$PENDING_NOTICE_FILE"
}

has_required_scopes() {
  local scopes_line scope
  scopes_line="$(gh auth status --hostname github.com 2>&1 | grep -i '^Scopes:' || true)"
  if [[ -z "$scopes_line" ]]; then
    return 1
  fi
  for scope in repo workflow "admin:org"; do
    if ! [[ "$scopes_line" =~ (^|[[:space:],])$scope($|[[:space:],]) ]]; then
      return 1
    fi
  done
  return 0
}

ensure_gh_scopes() {
  if has_required_scopes; then
    return 0
  fi
  local required="repo,workflow,admin:org"
  echo "Ensuring GitHub CLI token has scopes: $required" >&2
  gh auth refresh --hostname github.com --scopes "$required" >/dev/null 2>&1 || return 1
  has_required_scopes
}

ensure_repo_admin_access() {
  local has_admin
  has_admin=$(gh api "repos/${FULL_REPO}" --jq '.permissions.admin' 2>/dev/null) || return 1
  [[ "$has_admin" == "true" ]]
}

record_gh_user() {
  GH_USER="$(gh api user --jq '.login' 2>/dev/null || echo '')"
}


usage() {
  cat <<USAGE
Usage: $0 [options]

If no flags are supplied the script reads defaults from
  - \\$GITHUB_HARDENING_CONFIG (if set) or scripts/github-hardening.conf
  - git remote "origin" (to infer owner/repo)

Options:
  --owner OWNER                 GitHub organisation or user that owns the repo
  --repo REPO                   Repository name
  --protected-branch NAME       Branch to protect (default: main)
  --required-checks LIST        Comma-separated list of required status checks
  --staging-reviewer ID         Reviewer for staging environment (repeatable)
  --production-reviewer ID      Reviewer for production environment (repeatable)
  --staging-wait MINUTES        Wait timer (minutes) before staging deploys
  --production-wait MINUTES     Wait timer before production deploys
  --keep-prod-env               Do not delete the legacy "prod" environment
  --help                        Display this help

Reviewer IDs may be GitHub usernames or org/team identifiers in the form org:<org>/teams/<team>.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner)
        OWNER="$2"; shift 2 ;;
      --repo)
        REPO="$2"; shift 2 ;;
      --protected-branch)
        PROTECTED_BRANCH="$2"; shift 2 ;;
      --required-checks)
        IFS=',' read -r -a REQUIRED_CHECK_CONTEXTS <<< "$(trim "$2")"; shift 2 ;;
      --staging-reviewer)
        STAGING_REVIEWERS+=("$2"); shift 2 ;;
      --production-reviewer)
        PRODUCTION_REVIEWERS+=("$2"); shift 2 ;;
      --staging-wait)
        STAGING_WAIT_MINUTES="$2"; shift 2 ;;
      --production-wait)
        PRODUCTION_WAIT_MINUTES="$2"; shift 2 ;;
      --keep-prod-env)
        REMOVE_PROD_ENV=false; shift ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 1 ;;
    esac
  done

  if [[ -z "$OWNER" || -z "$REPO" ]]; then
    infer_repo_from_git || true
  fi

  if [[ -z "$OWNER" || -z "$REPO" ]]; then
    echo "Unable to determine repository owner/name. Set values in ${CONFIG_FILE}, pass --owner/--repo, or ensure git remote origin points to GitHub." >&2
    usage
    exit 1
  fi

  if [[ ${#REQUIRED_CHECK_CONTEXTS[@]} -eq 0 ]]; then
    IFS=',' read -r -a REQUIRED_CHECK_CONTEXTS <<< "$REQUIRED_CHECKS_DEFAULT"
  fi
}

trimmed_array() {
  local -n src="$1"
  local out=()
  for item in "${src[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] || continue
    out+=("$item")
  done
  printf '%s\0' "${out[@]}"
}

to_json_array() {
  local first=1
  printf '['
  for item in "$@"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] || continue
    if (( !first )); then
      printf ','
    fi
    printf '"%s"' "$item"
    first=0
  done
  printf ']'
}

FULL_REPO=""

require_gh() {
  if [[ "${SETUP_SKIP_GITHUB_HARDENING:-0}" == "1" ]]; then
    echo "Skipping GitHub repository hardening because SETUP_SKIP_GITHUB_HARDENING=1." >&2
    write_pending_notice
    return 0
  fi

  local attempt=1
  while true; do
    if gh auth status >/dev/null 2>&1; then
      record_gh_user
      if ensure_gh_scopes && ensure_repo_admin_access; then
        clear_pending_notice
        if [[ -n "$GH_USER" ]]; then
          echo "GitHub CLI authenticated as $GH_USER with admin access to ${FULL_REPO}."
        else
          echo "GitHub CLI authentication and permissions verified for ${FULL_REPO}."
        fi
        return 0
      fi
      echo "GitHub token lacks required scopes or administrator rights; attempting to refresh." >&2
      ensure_gh_scopes >/dev/null 2>&1 || true
    else
      echo "GitHub CLI is not authenticated." >&2
    fi

    if [[ ! -t 0 ]]; then
      write_pending_notice
      echo "Cannot complete GitHub authentication in a non-interactive environment." >&2
      exit 1
    fi

    echo "→ Starting gh auth login (attempt ${attempt})"
    gh auth login --hostname github.com --git-protocol https --web --scopes "repo,workflow,admin:org" || true

    if gh auth status >/dev/null 2>&1; then
      record_gh_user
      if ensure_gh_scopes && ensure_repo_admin_access; then
        clear_pending_notice
        echo "GitHub CLI authentication detected. Continuing repository hardening."
        return 0
      fi
      echo "Authenticated user does not have the required scopes or admin rights on ${FULL_REPO}." >&2
    else
      echo "GitHub authentication was not detected." >&2
    fi

    read -r -p "Retry GitHub authentication with a different account? [Y/n] " _retry
    _retry="${_retry:-Y}"
    if [[ ! "$_retry" =~ ^[Yy] ]]; then
      write_pending_notice
      echo "GitHub authentication with admin rights is required to configure repository hardening." >&2
      exit 1
    fi
    attempt=$((attempt + 1))
  done
}

enable_security_features() {
  echo "→ Enabling security & analysis features"

  local payload response
  payload='{
  "delete_branch_on_merge": true,
  "allow_auto_merge": true,
  "security_and_analysis": {
    "advanced_security": {"status": "enabled"},
    "dependabot_security_updates": {"status": "enabled"},
    "secret_scanning": {"status": "enabled"},
    "secret_scanning_push_protection": {"status": "enabled"}
  }
}'

  if ! response=$(printf '%s' "$payload" | gh api -X PATCH "repos/${FULL_REPO}" --input - 2>&1); then
    if [[ "$response" == *"Advanced security is always available"* ]]; then
      echo "   Skipping Advanced Security toggle (already enabled for public repositories)."
    else
      printf '%s\n' "$response" >&2
      exit 1
    fi
  fi

  if ! gh api -X PUT -H "Accept: application/vnd.github+json" "repos/${FULL_REPO}/vulnerability-alerts"; then
    echo "   Warning: unable to enable Dependabot vulnerability alerts (check permissions)." >&2
  fi

  if ! gh api -X PUT -H "Accept: application/vnd.github+json" "repos/${FULL_REPO}/automated-security-fixes"; then
    echo "   Warning: unable to enable automated security fixes (check permissions)." >&2
  fi

  if [[ -f "$REPO_ROOT/$CODEQL_WORKFLOW_PATH" ]]; then
    echo "   CodeQL workflow detected at $CODEQL_WORKFLOW_PATH; skipping default setup API call."
  else
    if ! gh api -X PUT -H "Accept: application/vnd.github+json" \
      "repos/${FULL_REPO}/code-scanning/default-setup" --input - <<'JSON'; then
{
  "state": "configured",
  "languages": ["javascript", "typescript"]
}
JSON
      echo "   Warning: unable to configure CodeQL default setup (check permissions or enable CodeQL manually)." >&2
    fi
  fi

}

configure_branch_protection() {
  echo "→ Applying branch protection to ${PROTECTED_BRANCH}"

  local contexts_json conversation_resolution pull_request_reviews_json
  contexts_json=$(to_json_array "${REQUIRED_CHECK_CONTEXTS[@]}")
  conversation_resolution=$(to_bool "${REQUIRE_CONVERSATION_RESOLUTION:-true}")

  if [[ "$(to_bool "${ENABLE_PR_REVIEWS:-true}")" == "true" ]]; then
    local dismiss require_code_owner reviews
    dismiss=$(to_bool "${DISMISS_STALE_REVIEWS:-true}")
    require_code_owner=$(to_bool "${REQUIRE_CODE_OWNER_REVIEWS:-true}")
    reviews=${REQUIRED_APPROVING_REVIEWS:-2}
    pull_request_reviews_json=$(cat <<EOF
{
  "dismiss_stale_reviews": ${dismiss},
  "require_code_owner_reviews": ${require_code_owner},
  "required_approving_review_count": ${reviews}
}
EOF
)
  else
    pull_request_reviews_json="null"
  fi

  local payload
  payload=$(cat <<EOF
{
  "required_status_checks": {
    "strict": true,
    "contexts": ${contexts_json}
  },
  "enforce_admins": true,
  "required_pull_request_reviews": ${pull_request_reviews_json},
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_linear_history": true,
  "require_conversation_resolution": ${conversation_resolution},
  "lock_branch": false,
  "allow_fork_syncing": false
}
EOF
)

  gh api -X PUT "repos/${FULL_REPO}/branches/${PROTECTED_BRANCH}/protection" \
    -H "Accept: application/vnd.github+json" \
    --input <(printf '%s' "$payload")
}

enforce_signed_commits() {
  if [[ "$(to_bool "${REQUIRE_SIGNED_COMMITS:-true}")" != "true" ]]; then
    echo "→ Skipping signed commit enforcement for ${PROTECTED_BRANCH}"
    return
  fi

  echo "→ Requiring signed commits on ${PROTECTED_BRANCH}"
  local response
  if ! response=$(gh api \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    "repos/${FULL_REPO}/branches/${PROTECTED_BRANCH}/protection/required_signatures" 2>&1); then
    if [[ "$response" == *"Required signatures already enabled"* ]]; then
      echo "   Signed commits already enforced on ${PROTECTED_BRANCH}."
    else
      printf '%s\n' "$response" >&2
      exit 1
    fi
  fi
}

resolve_reviewer_id() {
  local reviewer="$1"
  if [[ "$reviewer" == org:*/* ]]; then
    local org team
    org="${reviewer#org:}"
    org="${org%%/*}"
    team="${reviewer##*/}"
    gh api "orgs/${org}/teams/${team}" --jq '.id'
  else
    gh api "users/${reviewer}" --jq '.id'
  fi
}

reviewers_payload() {
  local -a reviewers=("$@")
  local first=1
  printf '['
  for reviewer in "${reviewers[@]}"; do
    reviewer="$(trim "$reviewer")"
    [[ -n "$reviewer" ]] || continue
    local type id_value
    if [[ "$reviewer" == org:*/* ]]; then
      type="team"
      id_value=$(resolve_reviewer_id "$reviewer")
    else
      type="user"
      id_value=$(resolve_reviewer_id "$reviewer")
    fi
    if (( !first )); then
      printf ','
    fi
    printf '{"type":"%s","id":%s}' "$type" "$id_value"
    first=0
  done
  printf ']'
}

configure_environment() {
  local env_name="$1"
  local wait_timer="$2"
  shift 2
  local -a reviewers=("$@")
  local reviewers_json

  if (( ${#reviewers[@]} )); then
    reviewers_json=$(reviewers_payload "${reviewers[@]}")
  else
    reviewers_json='[]'
  fi

  echo "→ Configuring environment ${env_name}"
  gh api -X PUT "repos/${FULL_REPO}/environments/${env_name}" --input - <<JSON
{
  "wait_timer": ${wait_timer},
  "deployment_branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": false
  },
  "reviewers": ${reviewers_json}
}
JSON
}

delete_environment_if_exists() {
  local env_name="$1"
  if gh api "repos/${FULL_REPO}/environments/${env_name}" >/dev/null 2>&1; then
    echo "→ Removing environment ${env_name}"
    gh api -X DELETE "repos/${FULL_REPO}/environments/${env_name}"
  fi
}

main() {
  load_config_if_present
  parse_args "$@"
  FULL_REPO="${OWNER}/${REPO}"

  require_gh
  enable_security_features
  configure_branch_protection
  enforce_signed_commits

  if [[ "$REMOVE_PROD_ENV" == true ]]; then
    delete_environment_if_exists "prod"
  fi

  configure_environment "staging" "$STAGING_WAIT_MINUTES" "${STAGING_REVIEWERS[@]}"
  configure_environment "production" "$PRODUCTION_WAIT_MINUTES" "${PRODUCTION_REVIEWERS[@]}"

  clear_pending_notice
  echo "✔ Repository hardening complete for ${FULL_REPO}."
}

main "$@"
