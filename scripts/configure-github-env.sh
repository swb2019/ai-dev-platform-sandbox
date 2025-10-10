#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: scripts/configure-github-env.sh [--repo <owner/repo>] <environment>

Creates or updates the GitHub Actions environment for staging or production.
Defaults are sourced from Terraform outputs (if available) and
.infra_bootstrap_state. Set AUTO_ACCEPT_DEFAULTS=0 to force prompts when defaults
exist; by default detected values are applied automatically.
USAGE
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

REPO_SLUG=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      shift || { echo "Missing value for --repo" >&2; exit 1; }
      REPO_SLUG="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ARGS+=("$1")
      ;;
  esac
  shift || break
done

if [[ ${#ARGS[@]} -ne 1 ]]; then
  usage >&2
  exit 1
fi

INPUT_ENVIRONMENT="${ARGS[0]}"
ENVIRONMENT_CANONICAL=""
ENVIRONMENT_DIR=""
ENVIRONMENT_PREFIX=""
case "${INPUT_ENVIRONMENT,,}" in
  staging)
    ENVIRONMENT_CANONICAL="staging"
    ENVIRONMENT_DIR="staging"
    ENVIRONMENT_PREFIX="STAGING"
    cluster_default="${STAGING_GKE_CLUSTER:-stg-autopilot}"
    endpoint_default="${STAGING_GKE_CLUSTER_ENDPOINT:-}"
    wif_provider_default="${STAGING_WORKLOAD_IDENTITY_PROVIDER:-}"
    wif_pool_default="${STAGING_WIF_POOL_NAME:-}"
    wif_provider_id_default="${STAGING_WIF_PROVIDER_ID:-stg-gha}"
    runtime_gsa_default="${STAGING_RUNTIME_GSA_EMAIL:-}"
    terraform_sa_default="${STAGING_TERRAFORM_SERVICE_ACCOUNT:-}"
    deploy_enabled_default="${STAGING_DEPLOY_ENABLED:-false}"
    infra_enabled_default="${STAGING_INFRA_ENABLED:-false}"
    ;;
  prod|production)
    ENVIRONMENT_CANONICAL="production"
    ENVIRONMENT_DIR="prod"
    ENVIRONMENT_PREFIX="PRODUCTION"
    cluster_default="${PRODUCTION_GKE_CLUSTER:-prod-autopilot}"
    endpoint_default="${PRODUCTION_GKE_CLUSTER_ENDPOINT:-}"
    wif_provider_default="${PRODUCTION_WORKLOAD_IDENTITY_PROVIDER:-}"
    wif_pool_default="${PRODUCTION_WIF_POOL_NAME:-}"
    wif_provider_id_default="${PRODUCTION_WIF_PROVIDER_ID:-prod-gha}"
    runtime_gsa_default="${PRODUCTION_RUNTIME_GSA_EMAIL:-}"
    terraform_sa_default="${PRODUCTION_TERRAFORM_SERVICE_ACCOUNT:-}"
    deploy_enabled_default="${PRODUCTION_DEPLOY_ENABLED:-false}"
    infra_enabled_default="${PRODUCTION_INFRA_ENABLED:-false}"
    ;;
  *)
    echo "Unsupported environment '${INPUT_ENVIRONMENT}'. Use 'staging' or 'prod'." >&2
    exit 1
    ;;
esac

if [[ -z "$REPO_SLUG" ]]; then
  origin_url=$(git config --get remote.origin.url || true)
  origin_url=${origin_url%.git}
  if [[ "$origin_url" =~ github.com[:/]+([^/]+/[A-Za-z0-9_.-]+)$ ]]; then
    REPO_SLUG="${BASH_REMATCH[1]}"
  fi
fi
REPO_SLUG=${REPO_SLUG%.git}
if [[ -z "$REPO_SLUG" ]]; then
  echo "Unable to determine repository slug automatically. Pass --repo <owner/repo>." >&2
  exit 1
fi

AUTO_ACCEPT_DEFAULTS_RAW="${AUTO_ACCEPT_DEFAULTS:-1}"
if [[ "$AUTO_ACCEPT_DEFAULTS_RAW" =~ ^(0|false|FALSE)$ ]]; then
  AUTO_ACCEPT_DEFAULTS=0
else
  AUTO_ACCEPT_DEFAULTS=1
fi

if [[ -t 0 && -t 1 ]]; then
  INTERACTIVE_SHELL=1
else
  INTERACTIVE_SHELL=0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh CLI is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

ENVIRONMENT_NAME="$ENVIRONMENT_CANONICAL"
ENV_DIR="$ROOT_DIR/infra/terraform/envs/$ENVIRONMENT_DIR"

printf "Configuring environment '%s' for repo '%s'\n" "$ENVIRONMENT_NAME" "$REPO_SLUG"

gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "/repos/$REPO_SLUG/environments/$ENVIRONMENT_NAME" \
  --field wait_timer=0 >/dev/null

# ---------------------------------------------------------------------------
# Gather defaults from Terraform outputs and bootstrap state
# ---------------------------------------------------------------------------

declare -A ENV_DEFAULTS=()

STATE_FILE="$ROOT_DIR/.infra_bootstrap_state"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

if command -v terraform >/dev/null 2>&1 && [[ -d "$ENV_DIR" ]]; then
  TF_OUTPUT=$(terraform -chdir="$ENV_DIR" output -json 2>/dev/null || true)
  if [[ -n "$TF_OUTPUT" ]]; then
    while IFS='=' read -r key value; do
      [[ -z "$key" ]] && continue
      ENV_DEFAULTS["$key"]="$value"
    done < <(TF_OUTPUT="$TF_OUTPUT" ENV_PREFIX="$ENVIRONMENT_PREFIX" python3 - <<'PY'
import json
import os

payload = os.environ.get("TF_OUTPUT", "")
prefix = os.environ.get("ENV_PREFIX")
if not payload or not prefix:
    exit()
try:
    data = json.loads(payload)
except json.JSONDecodeError:
    exit()

def get(name):
    node = data.get(name)
    if not node:
        return None
    return node.get("value")

def emit(suffix, value):
    if value:
        print(f"{prefix}_{suffix}={value}")

artifact = get("artifact_registry_repository")
if artifact:
    parts = artifact.split('/')
    if len(parts) >= 6:
        project = parts[1]
        location = parts[3]
        repo = parts[5]
        host = f"{location}-docker.pkg.dev"
        repo_path = f"{project}/{repo}"
        emit("ARTIFACT_REGISTRY_HOST", host)
        emit("IMAGE_REPO", f"{host}/{repo_path}")
        emit("GCP_PROJECT_ID", project)

emit("GKE_LOCATION", get("gke_location"))
cluster_name = get("cluster_name")
emit("GKE_CLUSTER", cluster_name)
emit("GKE_CLUSTER_NAME", cluster_name)
emit("GKE_CLUSTER_ENDPOINT", get("cluster_endpoint"))
emit("WORKLOAD_IDENTITY_PROVIDER", get("wif_provider_name"))
emit("WORKLOAD_IDENTITY_SERVICE_ACCOUNT", get("terraform_service_account_email"))
emit("RUNTIME_GSA_EMAIL", get("runtime_service_account_email"))
emit("WIF_PROVIDER_ID", get("wif_provider_id"))
emit("WIF_POOL_NAME", get("wif_pool_name"))
PY
    )
  fi
fi

case "$ENVIRONMENT_CANONICAL" in
  staging)
    ns_default="${STAGING_KSA_NAMESPACE:-web}"
    name_default="${STAGING_KSA_NAME:-web}"
    ba_default="${STAGING_BA_ATTESTORS:-}"
    artifact_repo_id_default="stg-docker"
    ;;
  production)
    ns_default="${PRODUCTION_KSA_NAMESPACE:-web}"
    name_default="${PRODUCTION_KSA_NAME:-web}"
    ba_default="${PRODUCTION_BA_ATTESTORS:-}"
    artifact_repo_id_default="prd-docker"
    ;;
  *)
    ns_default="web"
    name_default="web"
    ba_default=""
    artifact_repo_id_default=""
    ;;
esac

env_project_var="${ENVIRONMENT_PREFIX}_GCP_PROJECT_ID"
project_default="${!env_project_var:-${GCP_PROJECT_ID:-}}"

env_location_var="${ENVIRONMENT_PREFIX}_GKE_LOCATION"
region_default="${!env_location_var:-${GCP_REGION:-}}"

ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_RUNTIME_KSA_NAMESPACE"]="$ns_default"
ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_RUNTIME_KSA_NAME"]="$name_default"
if [[ -n "$ba_default" ]]; then
  ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_BA_ATTESTORS"]="$ba_default"
fi

project_stub="${project_default:-example-project}"
if [[ -z "$cluster_default" ]]; then
  if [[ "$ENVIRONMENT_CANONICAL" == "staging" ]]; then
    cluster_default="stg-autopilot"
  else
    cluster_default="prod-autopilot"
  fi
fi
if [[ -z "$endpoint_default" ]]; then
  endpoint_default=""
fi
if [[ -z "$wif_provider_default" ]]; then
  if [[ "$ENVIRONMENT_CANONICAL" == "staging" ]]; then
    wif_provider_default="projects/${project_stub}/locations/global/workloadIdentityPools/stg-github/providers/stg-gha"
  else
    wif_provider_default="projects/${project_stub}/locations/global/workloadIdentityPools/prod-github/providers/prod-gha"
  fi
fi
if [[ -z "$wif_pool_default" ]]; then
  if [[ "$ENVIRONMENT_CANONICAL" == "staging" ]]; then
    wif_pool_default="projects/${project_stub}/locations/global/workloadIdentityPools/stg-github"
  else
    wif_pool_default="projects/${project_stub}/locations/global/workloadIdentityPools/prod-github"
  fi
fi
if [[ -z "$wif_provider_id_default" ]]; then
  if [[ "$ENVIRONMENT_CANONICAL" == "staging" ]]; then
    wif_provider_id_default="stg-gha"
  else
    wif_provider_id_default="prod-gha"
  fi
fi
if [[ -z "$runtime_gsa_default" ]]; then
  if [[ "$ENVIRONMENT_CANONICAL" == "staging" ]]; then
    runtime_gsa_default="stg-runtime@${project_stub}.iam.gserviceaccount.com"
  else
    runtime_gsa_default="prod-runtime@${project_stub}.iam.gserviceaccount.com"
  fi
fi
if [[ -z "$terraform_sa_default" ]]; then
  if [[ "$ENVIRONMENT_CANONICAL" == "staging" ]]; then
    terraform_sa_default="stg-tf-admin@${project_stub}.iam.gserviceaccount.com"
  else
    terraform_sa_default="prod-tf-admin@${project_stub}.iam.gserviceaccount.com"
  fi
fi
ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_GKE_CLUSTER"]="$cluster_default"
ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_GKE_CLUSTER_NAME"]="$cluster_default"
if [[ -n "$endpoint_default" ]]; then
  ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_GKE_CLUSTER_ENDPOINT"]="$endpoint_default"
fi
ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_WORKLOAD_IDENTITY_PROVIDER"]="$wif_provider_default"
ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_WIF_PROVIDER_NAME"]="$wif_provider_default"
ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_WIF_PROVIDER_ID"]="$wif_provider_id_default"
ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_WIF_POOL_NAME"]="$wif_pool_default"
ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_RUNTIME_GSA_EMAIL"]="$runtime_gsa_default"
ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_WORKLOAD_IDENTITY_SERVICE_ACCOUNT"]="$terraform_sa_default"
ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_TERRAFORM_SERVICE_ACCOUNT"]="$terraform_sa_default"
ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_DEPLOY_ENABLED"]="$deploy_enabled_default"
ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_INFRA_ENABLED"]="$infra_enabled_default"

if [[ -n "$project_default" && -z "${!env_project_var:-}" ]]; then
  ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_GCP_PROJECT_ID"]="$project_default"
fi

if [[ -n "$region_default" && -z "${!env_location_var:-}" ]]; then
  ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_GKE_LOCATION"]="$region_default"
fi

if [[ -n "$region_default" ]]; then
  artifact_host_default="${region_default}-docker.pkg.dev"
  env_host_var="${ENVIRONMENT_PREFIX}_ARTIFACT_REGISTRY_HOST"
  if [[ -z "${!env_host_var:-}" ]]; then
    ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_ARTIFACT_REGISTRY_HOST"]="$artifact_host_default"
  fi
  if [[ -n "$project_default" && -n "$artifact_repo_id_default" ]]; then
    env_image_var="${ENVIRONMENT_PREFIX}_IMAGE_REPO"
    image_repo_default="${artifact_host_default}/${project_default}/${artifact_repo_id_default}/web"
    if [[ -z "${!env_image_var:-}" ]]; then
      ENV_DEFAULTS["${ENVIRONMENT_PREFIX}_IMAGE_REPO"]="$image_repo_default"
    fi
  fi
fi

for key in "${!ENV_DEFAULTS[@]}"; do
  value="${ENV_DEFAULTS[$key]}"
  [[ -z "$value" ]] && continue
  if [[ -z "${!key:-}" ]]; then
    export "$key=$value"
  fi
  # Clear from map if we exported (avoid reusing downstream)
  unset "ENV_DEFAULTS[$key]"

done


SECRET_KEYS=(
  "${ENVIRONMENT_PREFIX}_IMAGE_REPO"
  "${ENVIRONMENT_PREFIX}_ARTIFACT_REGISTRY_HOST"
  "${ENVIRONMENT_PREFIX}_GCP_PROJECT_ID"
  "${ENVIRONMENT_PREFIX}_GKE_LOCATION"
  "${ENVIRONMENT_PREFIX}_GKE_CLUSTER"
  "${ENVIRONMENT_PREFIX}_WORKLOAD_IDENTITY_PROVIDER"
  "${ENVIRONMENT_PREFIX}_WORKLOAD_IDENTITY_SERVICE_ACCOUNT"
  "${ENVIRONMENT_PREFIX}_RUNTIME_GSA_EMAIL"
  "${ENVIRONMENT_PREFIX}_RUNTIME_KSA_NAMESPACE"
  "${ENVIRONMENT_PREFIX}_RUNTIME_KSA_NAME"
  "${ENVIRONMENT_PREFIX}_BA_ATTESTORS"
  "${ENVIRONMENT_PREFIX}_TERRAFORM_SERVICE_ACCOUNT"
)

VARIABLE_KEYS=(
  "${ENVIRONMENT_PREFIX}_WIF_PROVIDER_ID"
  "${ENVIRONMENT_PREFIX}_WIF_POOL_NAME"
  "${ENVIRONMENT_PREFIX}_GKE_CLUSTER_NAME"
)

cluster_endpoint_var="${ENVIRONMENT_PREFIX}_GKE_CLUSTER_ENDPOINT"
if [[ -n "${!cluster_endpoint_var:-}" ]]; then
  VARIABLE_KEYS+=("$cluster_endpoint_var")
fi

VARIABLE_KEYS+=(
  "${ENVIRONMENT_PREFIX}_GKE_LOCATION"
  "${ENVIRONMENT_PREFIX}_DEPLOY_ENABLED"
  "${ENVIRONMENT_PREFIX}_INFRA_ENABLED"
)

if (( AUTO_ACCEPT_DEFAULTS )); then
  echo "Applying detected secrets (AUTO_ACCEPT_DEFAULTS=1)"
else
  echo "Enter secret values (leave blank to skip)"
fi
for key in "${SECRET_KEYS[@]}"; do
  default_value="${!key:-}"
  default_used=0
  value=""
  if [[ -n "$default_value" && ( AUTO_ACCEPT_DEFAULTS -eq 1 || INTERACTIVE_SHELL -eq 0 ) ]]; then
    value="$default_value"
    default_used=1
  elif [[ -n "$default_value" && INTERACTIVE_SHELL -eq 1 ]]; then
    printf "%s detected from infrastructure.\n" "$key"
    read -r -s -p "$key (press Enter to keep detected value): " value || value=""
    echo
    if [[ -z "$value" ]]; then
      value="$default_value"
      default_used=1
    fi
  elif (( INTERACTIVE_SHELL )); then
    read -r -s -p "$key: " value || value=""
    echo
  else
    echo "  - secret $key skipped (no value detected)"
  fi
  if [[ -n "$value" ]]; then
    printf "%s" "$value" | gh secret set "$key" --repo "$REPO_SLUG" --env "$ENVIRONMENT_NAME" --body - >/dev/null
    if (( default_used )); then
      echo "  ✓ secret $key updated (auto-detected)"
    else
      echo "  ✓ secret $key updated"
    fi
  elif (( INTERACTIVE_SHELL )); then
    echo "  - secret $key skipped"
  fi
done

echo
if (( AUTO_ACCEPT_DEFAULTS )); then
  echo "Applying detected environment variables (AUTO_ACCEPT_DEFAULTS=1)"
else
  echo "Enter plain-text environment variables (leave blank to skip)"
fi
for key in "${VARIABLE_KEYS[@]}"; do
  default_value="${!key:-}"
  default_used=0
  value=""
  if [[ -n "$default_value" && ( AUTO_ACCEPT_DEFAULTS -eq 1 || INTERACTIVE_SHELL -eq 0 ) ]]; then
    value="$default_value"
    default_used=1
  elif [[ -n "$default_value" && INTERACTIVE_SHELL -eq 1 ]]; then
    printf "%s detected: %s\n" "$key" "$default_value"
    read -r -p "$key (press Enter to keep detected value): " value || value=""
    if [[ -z "$value" ]]; then
      value="$default_value"
      default_used=1
    fi
  elif (( INTERACTIVE_SHELL )); then
    read -r -p "$key: " value || value=""
  else
    echo "  - variable $key skipped (no value detected)"
  fi
  if [[ -n "$value" ]]; then
    gh variable set "$key" --repo "$REPO_SLUG" --env "$ENVIRONMENT_NAME" --body "$value" >/dev/null
    if (( default_used )); then
      echo "  ✓ variable $key updated (auto-detected)"
    else
      echo "  ✓ variable $key updated"
    fi
  elif (( INTERACTIVE_SHELL )); then
    echo "  - variable $key skipped"
  fi
done

echo
echo "Environment '$ENVIRONMENT_NAME' configured for $REPO_SLUG."
echo "Review in GitHub → Settings → Environments → $ENVIRONMENT_NAME."
