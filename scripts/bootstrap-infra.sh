#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT_DIR/.infra_bootstrap_state"
SKIPPED_APPLY_ENVS=()

env_was_skipped() {
  local env_name="${1:-}"
  if [[ -z "$env_name" ]]; then
    return 1
  fi
  for skipped in "${SKIPPED_APPLY_ENVS[@]}"; do
    if [[ "$skipped" == "$env_name" ]]; then
      return 0
    fi
  done
  return 1
}



heading() {
  printf "\n%s\n" "==> $1"
}

prompt_yes() {
  local prompt="${1:-Continue?}" default="${2:-Y}" reply normalized_default
  normalized_default="${default:-Y}"
  normalized_default="${normalized_default:0:1}"
  case "${normalized_default}" in
    [YyNn]) ;;
    *) normalized_default="Y" ;;
  esac

  if [[ ! -t 0 ]]; then
    reply="$normalized_default"
  elif [[ "${normalized_default^^}" == "Y" ]]; then
    read -r -p "$prompt [Y/n] " reply || reply=""
    reply="${reply:-Y}"
  else
    read -r -p "$prompt [y/N] " reply || reply=""
    reply="${reply:-N}"
  fi

  reply="${reply:-$normalized_default}"
  reply="${reply//[[:space:]]/}"

  case "$reply" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_for() {
  local var_name="${1:-}"
  local prompt="${2:-}"
  local default="${3:-}"
  local value
  if [[ -z "$var_name" || -z "$prompt" ]]; then
    echo "prompt_for requires a variable name and prompt." >&2
    exit 1
  fi
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt ($default): " value || true
    else
      read -r -p "$prompt: " value || true
    fi
    value="${value:-$default}"
    if [[ -n "$value" ]]; then
      printf -v "$1" "%s" "$value"
      printf "%s=%s\n" "$var_name" "$value" >&2
      break
    fi
    echo "A value is required."
  done
}

write_state() {
  cat > "$STATE_FILE" <<EOF
GCP_PROJECT_ID="$GCP_PROJECT_ID"
GCP_REGION="$GCP_REGION"
GITHUB_ORG_REPO="$GITHUB_ORG_REPO"
TERRAFORM_STATE_BUCKET="${TERRAFORM_STATE_BUCKET:-}"
STAGING_KSA_NAMESPACE="${STAGING_KSA_NAMESPACE:-}"
STAGING_KSA_NAME="${STAGING_KSA_NAME:-}"
PRODUCTION_KSA_NAMESPACE="${PRODUCTION_KSA_NAMESPACE:-}"
PRODUCTION_KSA_NAME="${PRODUCTION_KSA_NAME:-}"
STAGING_BA_ATTESTORS="${STAGING_BA_ATTESTORS:-}"
PRODUCTION_BA_ATTESTORS="${PRODUCTION_BA_ATTESTORS:-}"
BOOTSTRAP_COMPLETED="$BOOTSTRAP_COMPLETED"
EOF
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

ensure_gcs_bucket() {
  local bucket_name="$1"

  while true; do
    if gcloud storage buckets describe "gs://$bucket_name" --project "$GCP_PROJECT_ID" >/dev/null 2>&1; then
      echo "GCS bucket gs://$bucket_name already exists."
      return 0
    fi

    echo "Creating GCS bucket gs://$bucket_name..."
    local output
    local create_args=("gs://$bucket_name" --project "$GCP_PROJECT_ID" --location "$GCP_REGION" --uniform-bucket-level-access)
    local -a pap_update_candidates=()
    if gcloud storage buckets update --help 2>/dev/null | grep -q -- "--pap"; then
      pap_update_candidates+=(--pap)
    fi
    if gcloud storage buckets update --help 2>/dev/null | grep -q -- "--public-access-prevention"; then
      pap_update_candidates+=(--public-access-prevention=enforced)
    fi

    if ! output=$(gcloud storage buckets create "${create_args[@]}" 2>&1); then
      if echo "$output" | grep -q "The requested bucket name is not available"; then
        echo "Bucket name '$bucket_name' is not available." >&2
        prompt_for TERRAFORM_STATE_BUCKET "Enter Terraform state bucket name" "${TERRAFORM_STATE_BUCKET:-}"
        write_state
        bucket_name="$TERRAFORM_STATE_BUCKET"
        continue
      fi
      echo "$output" >&2
      return 1
    fi

    echo "Enforcing public access prevention on gs://$bucket_name..."
    local pap_applied=0
    if (( ${#pap_update_candidates[@]} > 0 )); then
      for candidate in "${pap_update_candidates[@]}"; do
        if gcloud storage buckets update "gs://$bucket_name" "$candidate" >/dev/null 2>&1; then
          pap_applied=1
          break
        fi
      done
    fi
    if (( pap_applied == 0 )); then
      gcloud storage buckets update "gs://$bucket_name" --pap >/dev/null 2>&1 || \
        gcloud storage buckets update "gs://$bucket_name" --public-access-prevention=enforced >/dev/null 2>&1 || true
    fi

    echo "Enabling versioning on gs://$bucket_name..."
    gcloud storage buckets update "gs://$bucket_name" --versioning
    return 0
  done
}


ensure_binary_authorization_attestor() {
  local var_name="$1" env_label="$2"
  if [[ -z "$var_name" || -z "$env_label" ]]; then
    echo "Binary Authorization attestor helper requires variable name and environment label." >&2
    exit 1
  fi
  local current_value="${!var_name:-}"
  if [[ -n "$current_value" ]]; then
    if [[ "$current_value" =~ ^projects/.+/attestors/.+$ ]]; then
      return 0
    fi
    echo "Stored Binary Authorization attestor for ${env_label} is malformed; recreating." >&2
  fi
  if [[ ! -x "$ROOT_DIR/scripts/create-binauthz-attestor.sh" ]]; then
    echo "Helper script $ROOT_DIR/scripts/create-binauthz-attestor.sh not found or not executable." >&2
    exit 1
  fi

  heading "Create Binary Authorization attestor (${env_label})"
  local attestor_resource
  if ! attestor_resource="$("$ROOT_DIR/scripts/create-binauthz-attestor.sh" "$env_label" "$GCP_PROJECT_ID")"; then
    echo "Failed to create Binary Authorization attestor for ${env_label}." >&2
    exit 1
  fi
  attestor_resource="${attestor_resource//$'\r'/}"
  attestor_resource="${attestor_resource//$'\n'/}"
  if [[ -z "$attestor_resource" ]]; then
    echo "Binary Authorization attestor creation did not return a resource name." >&2
    exit 1
  fi

  printf -v "$var_name" "%s" "$attestor_resource"
  write_state
  echo "Configured ${env_label} attestor: $attestor_resource"
}

ensure_binary_authorization_attestors() {
  ensure_binary_authorization_attestor STAGING_BA_ATTESTORS staging
  ensure_binary_authorization_attestor PRODUCTION_BA_ATTESTORS production
}




find_python() {

  if command -v python3 >/dev/null 2>&1; then
    echo "python3"
  elif command -v python >/dev/null 2>&1; then
    echo "python"
  else
    echo ""
  fi
}

update_backend_file() {
  local file_path="$1" bucket_name="$2" python_bin
  python_bin="$(find_python)"
  if [[ -z "$python_bin" ]]; then
    echo "python3 (or python) is required to update backend files." >&2
    exit 1
  fi

  if [[ ! -f "$file_path" ]]; then
    echo "Backend file $file_path not found." >&2
    exit 1
  fi

  "$python_bin" - "$file_path" "$bucket_name" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
bucket = sys.argv[2]
text = path.read_text()
pattern = re.compile(r'(bucket\s*=\s*")([^"]*)(")')
match = pattern.search(text)
if not match:
    raise SystemExit(f"Unable to find bucket configuration in {path}")
if match.group(2) != bucket:
    text = text[:match.start(2)] + bucket + text[match.end(2):]
    path.write_text(text)
PY

  echo "Updated backend bucket in $file_path"
}

run_terraform_for_env() {
  local env_name="${1:-}"
  if [[ -z "$env_name" ]]; then
    echo "Environment name is required for run_terraform_for_env." >&2
    exit 1
  fi

  local env_dir="$ROOT_DIR/infra/terraform/envs/$env_name"
  if [[ ! -d "$env_dir" ]]; then
    echo "Terraform environment directory $env_dir not found." >&2
    exit 1
  fi

  local -a tf_env_common=(
    "TF_VAR_project_id=$GCP_PROJECT_ID"
    "TF_VAR_region=$GCP_REGION"
    "TF_VAR_github_repository=$GITHUB_ORG_REPO"
  )
  local -a tf_env_extra=()

  local attestors_input attestors_json

  case "$env_name" in
    staging)
      attestors_input="$STAGING_BA_ATTESTORS"
      tf_env_extra=(
        "TF_VAR_runtime_service_account_namespace=$STAGING_KSA_NAMESPACE"
        "TF_VAR_runtime_service_account_name=$STAGING_KSA_NAME"
      )
      local cluster_name="stg-autopilot"
      ;;
    prod|production)
      attestors_input="$PRODUCTION_BA_ATTESTORS"
      tf_env_extra=(
        "TF_VAR_runtime_service_account_namespace=$PRODUCTION_KSA_NAMESPACE"
        "TF_VAR_runtime_service_account_name=$PRODUCTION_KSA_NAME"
      )
      local cluster_name="prod-autopilot"
      ;;
    *)
      echo "Unknown environment $env_name." >&2
      exit 1
      ;;
  esac

  attestors_json="$(normalize_attestors_input "$attestors_input")" || {
    echo "Failed to normalize Binary Authorization attestors for $env_name." >&2
    exit 1
  }

  tf_env_extra+=("TF_VAR_binary_authorization_attestors=$attestors_json")

  local -a tf_env=("${tf_env_common[@]}" "${tf_env_extra[@]}")

  heading "Terraform init ($env_name)"
  (cd "$env_dir" && env "${tf_env[@]}" terraform init -upgrade)

  local cluster_location="$GCP_REGION"
  local cluster_resource="projects/$GCP_PROJECT_ID/locations/$cluster_location/clusters/${cluster_name}"
  if gcloud container clusters describe "$cluster_name" --location "$cluster_location" --project "$GCP_PROJECT_ID" >/dev/null 2>&1; then
    if ! (cd "$env_dir" && env "${tf_env[@]}" terraform state show module.gke.google_container_cluster.this >/dev/null 2>&1); then
      heading "Import existing GKE cluster ($env_name)"
      (cd "$env_dir" && env "${tf_env[@]}" terraform import module.gke.google_container_cluster.this "$cluster_resource") || true
    fi
  fi

  if prompt_yes "Run terraform apply for $env_name now?" "Y"; then
    heading "Terraform apply ($env_name)"
    (cd "$env_dir" && env "${tf_env[@]}" terraform apply)
  else
    echo "Skipping terraform apply for $env_name at user request."
    SKIPPED_APPLY_ENVS+=("$env_name")
  fi
}


declare -A TERRAFORM_OUTPUTS_JSON=()

normalize_attestors_input() {
  local raw="${1:-}"
  local python_bin json
  python_bin="$(find_python)"
  if [[ -z "$python_bin" ]]; then
    echo "python3 (or python) is required to normalize attestors." >&2
    exit 1
  fi

  if [[ -z "$raw" ]]; then
    echo "Binary Authorization attestors cannot be empty." >&2
    return 1
  fi

  json="$(
    RAW_ATTESTORS_INPUT="$raw" "$python_bin" - <<'PY'
import json
import os
import sys

text = os.environ.get("RAW_ATTESTORS_INPUT", "").strip()
if not text:
    raise SystemExit("Binary Authorization attestors cannot be empty.")

if text.startswith('['):
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON attestors list: {exc}")
    if not isinstance(data, list) or not all(isinstance(item, str) for item in data):
        raise SystemExit("Binary Authorization attestors JSON must be a list of strings.")
    cleaned = [item.strip() for item in data if item.strip()]
else:
    cleaned = [segment.strip() for segment in text.split(',') if segment.strip()]

if not cleaned:
    raise SystemExit("Binary Authorization attestors cannot be empty.")

print(json.dumps(cleaned, separators=(',', ':')))
PY
  )" || return 1

  printf "%s" "$json"
}

capture_terraform_outputs() {
  local env_name="${1:-}"
  if [[ -z "$env_name" ]]; then
    echo "Environment name is required for capture_terraform_outputs." >&2
    return 1
  fi
  local env_dir="$ROOT_DIR/infra/terraform/envs/$env_name" output_json
  if env_was_skipped "$env_name"; then
    echo "Skipping Terraform output capture for $env_name (apply skipped)."
    return 0
  fi
  if [[ ! -d "$env_dir" ]]; then
    echo "Terraform environment directory $env_dir not found." >&2
    return 1
  fi
  if ! output_json="$(cd "$env_dir" && terraform output -json 2>/dev/null)"; then
    echo "Unable to read Terraform outputs for $env_name." >&2
    return 1
  fi
  TERRAFORM_OUTPUTS_JSON["$env_name"]="$output_json"
}

extract_output_value() {
  local env_name="${1:-}"
  local key="${2:-}"
  if [[ -z "$env_name" || -z "$key" ]]; then
    return 1
  fi
  local json="${TERRAFORM_OUTPUTS_JSON[$env_name]:-}"
  local python_bin result
  if [[ -z "$json" ]]; then
    return 1
  fi

  python_bin="$(find_python)"
  if [[ -z "$python_bin" ]]; then
    echo "python3 (or python) is required to parse Terraform outputs." >&2
    exit 1
  fi

  if ! result="$(OUTPUT_JSON="$json" OUTPUT_KEY="$key" "$python_bin" - <<'PYSCRIPT'
import json
import os
import sys

payload = os.environ.get("OUTPUT_JSON", "")
key = os.environ.get("OUTPUT_KEY")
if not payload or not key:
    raise SystemExit(1)

data = json.loads(payload)
value = data.get(key, {}).get("value")
if value is None:
    raise SystemExit(1)

if isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PYSCRIPT
)"; then
    return 1
  fi

  printf "%s" "$result"
}

refresh_gcloud_credentials_if_needed() {
  if gcloud auth print-access-token >/dev/null 2>&1; then
    return 0
  fi

  echo "Active gcloud credentials need to be refreshed."
  if prompt_yes "Run gcloud auth login now?" "Y"; then
    gcloud auth login --project "$GCP_PROJECT_ID"
    if gcloud auth print-access-token >/dev/null 2>&1; then
      return 0
    fi
    echo "gcloud auth login did not refresh credentials successfully." >&2
  else
    echo "Cannot continue without refreshed gcloud credentials." >&2
  fi

  exit 1
}

ensure_attestor_signing_permissions_for_env() {
  local env_label="${1:-}"
  local tf_env="${2:-}"
  local attestor_resource="${3:-}"

  if [[ -z "$env_label" || -z "$tf_env" ]]; then
    echo "Environment label and Terraform environment name are required for attestor IAM configuration." >&2
    exit 1
  fi

  if [[ -z "$attestor_resource" ]]; then
    echo "No Binary Authorization attestor configured for ${env_label}; skipping IAM binding."
    return 0
  fi

  if [[ -z "${TERRAFORM_OUTPUTS_JSON[$tf_env]:-}" ]]; then
    echo "Terraform outputs missing for ${env_label}; skipping Binary Authorization IAM binding."
    return 0
  fi

  local python_bin
  python_bin="$(find_python)"
  if [[ -z "$python_bin" ]]; then
    echo "python3 (or python) is required to manage Binary Authorization IAM bindings." >&2
    exit 1
  fi

  local service_account
  if ! service_account="$(extract_output_value "$tf_env" terraform_service_account_email 2>/dev/null)"; then
    echo "Unable to determine Terraform service account for ${env_label}; skipping Binary Authorization IAM binding." >&2
    return 1
  fi
  service_account="${service_account//$'\r'/}"
  service_account="${service_account//$'\n'/}"
  if [[ -z "$service_account" ]]; then
    echo "Terraform service account email for ${env_label} is empty; skipping Binary Authorization IAM binding." >&2
    return 1
  fi

  attestor_resource="${attestor_resource//$'\r'/}"
  attestor_resource="${attestor_resource//$'\n'/}"
  local attestor_id="${attestor_resource##*/}"
  local member="serviceAccount:${service_account}"
  local -a attestor_roles=(
    "roles/binaryauthorization.attestorsVerifier"
  )

  local attestor_json
  if ! attestor_json=$(gcloud container binauthz attestors describe "$attestor_id" --project "$GCP_PROJECT_ID" --format=json 2>/dev/null); then
    echo "Unable to describe attestor ${attestor_resource}; skipping IAM binding." >&2
    return 1
  fi

  local note_reference
  note_reference="$("$python_bin" - <<'PYIN'
import json
import sys

data = json.loads(sys.stdin.read() or "{}")
print(data.get("userOwnedGrafeasNote", {}).get("noteReference", ""))
PYIN
<<<"$attestor_json")"

  local policy_json
  if ! policy_json=$(gcloud container binauthz attestors get-iam-policy "$attestor_id" --project "$GCP_PROJECT_ID" --format=json 2>/dev/null); then
    echo "Unable to fetch IAM policy for attestor ${attestor_resource} in project ${GCP_PROJECT_ID}." >&2
    return 1
  fi

  local role heading_printed=0
  for role in "${attestor_roles[@]}"; do
    if POLICY_JSON="$policy_json" MEMBER="$member" ROLE="$role" "$python_bin" <<'PY'
import json, os, sys
policy = json.loads(os.environ.get("POLICY_JSON") or "{}")
target_role = os.environ["ROLE"]
target_member = os.environ["MEMBER"]
for binding in policy.get("bindings", []):
    if binding.get("role") == target_role and target_member in (binding.get("members") or []):
        sys.exit(0)
sys.exit(1)
PY
    then
      continue
    fi

    if (( heading_printed == 0 )); then
      heading "Grant Binary Authorization roles (${env_label})"
      heading_printed=1
    fi

    echo "Granting ${role} to ${member} on attestor ${attestor_id}"
    gcloud container binauthz attestors add-iam-policy-binding "$attestor_id" \
      --project "$GCP_PROJECT_ID" \
      --member "$member" \
      --role "$role"
    policy_json=$(gcloud container binauthz attestors get-iam-policy "$attestor_id" --project "$GCP_PROJECT_ID" --format=json 2>/dev/null)
  done

  ensure_note_attacher_binding "$note_reference" "$member" "${env_label}"

  if (( heading_printed == 0 )); then
    echo "Binary Authorization attestor ${attestor_id} already grants required roles to ${member}."
  fi
}

ensure_attestor_signing_permissions() {
  ensure_attestor_signing_permissions_for_env "staging" "staging" "${STAGING_BA_ATTESTORS:-}"
  ensure_attestor_signing_permissions_for_env "production" "prod" "${PRODUCTION_BA_ATTESTORS:-}"
}

ensure_note_attacher_binding() {
  local note_resource="${1:-}"
  local member="${2:-}"
  local env_label="${3:-}"
  local role="roles/containeranalysis.notes.attacher"

  if [[ -z "$note_resource" ]]; then
    echo "Binary Authorization attestor for ${env_label:-unknown environment} is not linked to a Grafeas note; skipping note IAM update."
    return 0
  fi

  if [[ -z "$member" ]]; then
    echo "Skipping Binary Authorization note IAM update for ${note_resource}; member is empty." >&2
    return 1
  fi

  local access_token
  access_token="$(gcloud auth print-access-token 2>/dev/null | tr -d '\r')"
  if [[ -z "$access_token" ]]; then
    echo "Unable to obtain access token to update IAM policy for ${note_resource}." >&2
    return 1
  fi

  local python_bin
  python_bin="$(find_python)"
  if [[ -z "$python_bin" ]]; then
    echo "python3 (or python) is required to update Binary Authorization note IAM policy." >&2
    return 1
  fi

  local get_response http_status policy_json
  get_response=$(curl -sS -X POST \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    "https://containeranalysis.googleapis.com/v1/${note_resource}:getIamPolicy" \
    -d '{}' -w '\n%{http_code}')
  http_status=${get_response##*$'\n'}
  policy_json=${get_response%$'\n'$http_status}
  if [[ $http_status -lt 200 || $http_status -ge 300 ]]; then
    echo "Failed to read IAM policy for ${note_resource} (status $http_status)." >&2
    [[ -n "$policy_json" ]] && echo "$policy_json" >&2
    return 1
  fi

  local updated_policy
  updated_policy=$(POLICY_MEMBER="$member" POLICY_ROLE="$role" POLICY_JSON="$policy_json" "$python_bin" - <<'PYIN'
import json
import os

text = os.environ.get('POLICY_JSON') or ''
member = os.environ['POLICY_MEMBER']
role = os.environ['POLICY_ROLE']
if text.strip():
    policy = json.loads(text)
else:
    policy = {}

bindings = policy.setdefault('bindings', [])
for binding in bindings:
    if binding.get('role') == role:
        members = binding.setdefault('members', [])
        if member in members:
            print('__UNCHANGED__')
            break
        members.append(member)
        print(json.dumps(policy, separators=(',', ':')))
        break
else:
    bindings.append({'role': role, 'members': [member]})
    print(json.dumps(policy, separators=(',', ':')))
PYIN
)

  if [[ "$updated_policy" == "__UNCHANGED__" || -z "$updated_policy" ]]; then
    echo "Binary Authorization note ${note_resource} already grants ${role} to ${member}."
    return 0
  fi

  local payload
  payload=$(UPDATED_POLICY="$updated_policy" "$python_bin" - <<'PYIN'
import json
import os

policy_json = os.environ.get('UPDATED_POLICY')
policy = json.loads(policy_json)
print(json.dumps({'policy': policy}))
PYIN
)

  local set_response
  set_response=$(curl -sS -X POST \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    "https://containeranalysis.googleapis.com/v1/${note_resource}:setIamPolicy" \
    -d "$payload" -w '\n%{http_code}')
  http_status=${set_response##*$'\n'}
  local set_body=${set_response%$'\n'$http_status}
  if [[ $http_status -lt 200 || $http_status -ge 300 ]]; then
    echo "Failed to update IAM policy for ${note_resource} (status $http_status)." >&2
    [[ -n "$set_body" ]] && echo "$set_body" >&2
    return 1
  fi

  echo "Granted ${role} to ${member} on Binary Authorization note ${note_resource}."
  return 0
}

enable_project_service() {
  local service="${1:-}"
  local label="${2:-$service}"
  local output

  if [[ -z "$service" ]]; then
    return 0
  fi

  if ! output=$(gcloud services enable "$service" --project "$GCP_PROJECT_ID" 2>&1); then
    if echo "$output" | grep -Eqi 'reauthentication failed|gcloud auth login'; then
      echo "gcloud session requires reauthentication before enabling ${label}."
      refresh_gcloud_credentials_if_needed
      if output=$(gcloud services enable "$service" --project "$GCP_PROJECT_ID" 2>&1); then
        return 0
      fi
    fi
    echo "Failed to enable ${label} API ($service)." >&2
    echo "$output" >&2
    return 1
  fi

  return 0
}

ensure_github_environment() {
  local env_name="${1:-}"
  if [[ -z "$env_name" ]]; then
    echo "Environment name is required for ensure_github_environment." >&2
    exit 1
  fi
  gh api \
    --method PUT \
    -H "Accept: application/vnd.github+json" \
    "/repos/$GITHUB_ORG_REPO/environments/$env_name" >/dev/null
}

set_env_secret() {
  local env_name="${1:-}"
  local key="${2:-}"
  local value="${3:-}"
  if [[ -z "$env_name" || -z "$key" ]]; then
    echo "Environment and key are required for set_env_secret." >&2
    return 1
  fi
  if [[ -z "$value" ]]; then
    echo "Skipping secret $key for $env_name (empty value)." >&2
    return 1
  fi
  if ! printf "%s" "$value" | gh secret set "$key" --env "$env_name" --repo "$GITHUB_ORG_REPO" >/dev/null; then
    echo "Failed to set secret $key for $env_name." >&2
    return 1
  fi
}

set_env_variable() {
  local env_name="${1:-}"
  local key="${2:-}"
  local value="${3:-}"
  if [[ -z "$env_name" || -z "$key" ]]; then
    echo "Environment and key are required for set_env_variable." >&2
    return 1
  fi
  if [[ -z "$value" ]]; then
    echo "Skipping variable $key for $env_name (empty value)." >&2
    return 1
  fi
  gh variable set "$key" --env "$env_name" --repo "$GITHUB_ORG_REPO" --body "$value" >/dev/null
}

sync_github_environment() {
  local env_name="${1:-}"
  local tf_env_name="${2:-$env_name}"
  if [[ -z "$env_name" ]]; then
    echo "Environment name is required for sync_github_environment." >&2
    return 1
  fi
  local ksa_namespace ksa_name attestors_input attestors_json
  local terraform_sa runtime_sa wif_provider wif_provider_id wif_pool cluster_name cluster_endpoint gke_location

  if [[ -z "${TERRAFORM_OUTPUTS_JSON[$tf_env_name]:-}" ]]; then
    echo "Skipping GitHub environment sync for $env_name (no Terraform outputs captured)."
    return
  fi

  case "$env_name" in
    staging)
      ksa_namespace="$STAGING_KSA_NAMESPACE"
      ksa_name="$STAGING_KSA_NAME"
      attestors_input="$STAGING_BA_ATTESTORS"
      ;;
    prod|production)
      ksa_namespace="$PRODUCTION_KSA_NAMESPACE"
      ksa_name="$PRODUCTION_KSA_NAME"
      attestors_input="$PRODUCTION_BA_ATTESTORS"
      ;;
    *)
      echo "Unknown environment $env_name." >&2
      return 1
      ;;
  esac

  if [[ -z "$ksa_namespace" || -z "$ksa_name" ]]; then
    echo "Runtime KSA namespace/name must be provided for $env_name." >&2
    exit 1
  fi

  if [[ -z "$attestors_input" ]]; then
    echo "Binary Authorization attestors must be provided for $env_name." >&2
    exit 1
  fi

  attestors_json="$(normalize_attestors_input "$attestors_input")" || {
    echo "Failed to normalize Binary Authorization attestors for $env_name." >&2
    exit 1
  }

  if ! terraform_sa="$(extract_output_value "$tf_env_name" terraform_service_account_email)"; then
    echo "Missing terraform_service_account_email output for $env_name." >&2
    return 1
  fi

  if ! wif_provider="$(extract_output_value "$tf_env_name" wif_provider_name)"; then
    echo "Missing wif_provider_name output for $env_name." >&2
    return 1
  fi

  if ! runtime_sa="$(extract_output_value "$tf_env_name" runtime_service_account_email)"; then
    runtime_sa=""
  fi

  if ! wif_provider_id="$(extract_output_value "$tf_env_name" wif_provider_id)"; then
    wif_provider_id=""
  fi

  if ! wif_pool="$(extract_output_value "$tf_env_name" wif_pool_name)"; then
    wif_pool=""
  fi

  if ! cluster_name="$(extract_output_value "$tf_env_name" cluster_name)"; then
    cluster_name=""
  fi

  if ! cluster_endpoint="$(extract_output_value "$tf_env_name" cluster_endpoint)"; then
    cluster_endpoint=""
  fi

  if ! gke_location="$(extract_output_value "$tf_env_name" gke_location)"; then
    gke_location="$GCP_REGION"
  fi

  ensure_github_environment "$env_name"

  local secret_prefix variable_prefix
  case "$env_name" in
    staging)
      secret_prefix="STAGING"
      variable_prefix="STAGING"
      ;;
    production)
      secret_prefix="PRODUCTION"
      variable_prefix="PRODUCTION"
      ;;
    *)
      secret_prefix="${env_name^^}"
      variable_prefix="${env_name^^}"
      ;;
  esac

  set_env_secret "$env_name" "${secret_prefix}_GCP_PROJECT_ID" "$GCP_PROJECT_ID"
  set_env_secret "$env_name" "${secret_prefix}_GCP_REGION" "$GCP_REGION"
  set_env_secret "$env_name" "${secret_prefix}_TERRAFORM_SERVICE_ACCOUNT" "$terraform_sa"
  set_env_secret "$env_name" "${secret_prefix}_WORKLOAD_IDENTITY_PROVIDER" "$wif_provider"
  set_env_secret "$env_name" "GCP_PROJECT_ID" "$GCP_PROJECT_ID"
  set_env_secret "$env_name" "GCP_REGION" "$GCP_REGION"
  set_env_secret "$env_name" "TERRAFORM_SERVICE_ACCOUNT" "$terraform_sa"
  set_env_secret "$env_name" "WORKLOAD_IDENTITY_PROVIDER" "$wif_provider"
  if [[ -n "$runtime_sa" ]]; then
    set_env_secret "$env_name" "${secret_prefix}_RUNTIME_SERVICE_ACCOUNT_EMAIL" "$runtime_sa"
    set_env_secret "$env_name" "RUNTIME_SERVICE_ACCOUNT_EMAIL" "$runtime_sa"
  fi
  set_env_secret "$env_name" "${secret_prefix}_RUNTIME_KSA_NAMESPACE" "$ksa_namespace"
  set_env_secret "$env_name" "${secret_prefix}_RUNTIME_KSA_NAME" "$ksa_name"
  set_env_secret "$env_name" "${secret_prefix}_BA_ATTESTORS" "$attestors_json"
  set_env_secret "$env_name" "RUNTIME_KSA_NAMESPACE" "$ksa_namespace"
  set_env_secret "$env_name" "RUNTIME_KSA_NAME" "$ksa_name"
  set_env_secret "$env_name" "BA_ATTESTORS" "$attestors_json"

  if [[ -n "$wif_provider_id" ]]; then
    set_env_variable "$env_name" "${variable_prefix}_WIF_PROVIDER_ID" "$wif_provider_id"
    set_env_variable "$env_name" "WIF_PROVIDER_ID" "$wif_provider_id"
  fi
  if [[ -n "$wif_pool" ]]; then
    set_env_variable "$env_name" "${variable_prefix}_WIF_POOL_NAME" "$wif_pool"
    set_env_variable "$env_name" "WIF_POOL_NAME" "$wif_pool"
  fi
  if [[ -n "$cluster_name" ]]; then
    set_env_variable "$env_name" "${variable_prefix}_GKE_CLUSTER_NAME" "$cluster_name"
    set_env_variable "$env_name" "GKE_CLUSTER_NAME" "$cluster_name"
  fi
  if [[ -n "$cluster_endpoint" ]]; then
    set_env_variable "$env_name" "${variable_prefix}_GKE_CLUSTER_ENDPOINT" "$cluster_endpoint"
    set_env_variable "$env_name" "GKE_CLUSTER_ENDPOINT" "$cluster_endpoint"
  fi
  set_env_variable "$env_name" "${variable_prefix}_GKE_LOCATION" "$gke_location"
  set_env_variable "$env_name" "GKE_LOCATION" "$gke_location"
}


ensure_gcloud_project_access() {
  heading "Validate gcloud project access"

  refresh_gcloud_credentials_if_needed

  echo "Ensuring foundational Google APIs are enabled..."
  enable_project_service serviceusage.googleapis.com "Service Usage" || {
    echo "Unable to enable Service Usage API for $GCP_PROJECT_ID." >&2
    exit 1
  }
  enable_project_service cloudresourcemanager.googleapis.com "Cloud Resource Manager" || {
    echo "Unable to enable Cloud Resource Manager API for $GCP_PROJECT_ID." >&2
    exit 1
  }

  while true; do
    local describe_output=""
    if describe_output="$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(projectId)" 2>&1)"; then
      local services_ready=0
      if gcloud services list --project "$GCP_PROJECT_ID" --format="value(config.name)" --limit=1 >/dev/null 2>&1; then
        services_ready=1
      else
        echo "Attempting to enable serviceusage.googleapis.com (required before other APIs)..."
        if gcloud services enable serviceusage.googleapis.com --project "$GCP_PROJECT_ID" >/dev/null 2>&1; then
          services_ready=1
        else
          echo "Account $ACTIVE_GCLOUD_ACCOUNT cannot manage services on project $GCP_PROJECT_ID." >&2
          echo "Request a role such as roles/serviceusage.serviceUsageAdmin or roles/editor." >&2
        fi
      fi

      if (( services_ready )); then
        if ! gcloud config set project "$GCP_PROJECT_ID" >/dev/null 2>&1; then
          echo "Warning: unable to set the active gcloud project. Continuing with explicit --project=$GCP_PROJECT_ID." >&2
        fi
        return 0
      fi
    else
      echo "Unable to describe project $GCP_PROJECT_ID with account $ACTIVE_GCLOUD_ACCOUNT." >&2
      echo "$describe_output" >&2
    fi

    echo ""
    echo "Current gcloud account: $ACTIVE_GCLOUD_ACCOUNT"
    if prompt_yes "Switch gcloud account?" "Y"; then
      gcloud auth login --project "$GCP_PROJECT_ID"
      ACTIVE_GCLOUD_ACCOUNT="$(gcloud config get-value account 2>/dev/null | tr -d '\r')"
      if [[ -z "$ACTIVE_GCLOUD_ACCOUNT" ]]; then
        echo "gcloud auth login failed to set an active account." >&2
        exit 1
      fi
      continue
    fi

    if prompt_yes "Enter a different GCP project ID?" "N"; then
      prompt_for GCP_PROJECT_ID "Enter GCP project ID" "${GCP_PROJECT_ID:-}"
      write_state
      continue
    fi

    echo "Cannot continue without service management access; exiting." >&2
    exit 1
  done
}

ensure_application_default_credentials() {
  if gcloud auth application-default print-access-token >/dev/null 2>&1; then
    return 0
  fi

  echo "Terraform requires Google Application Default Credentials."
  if prompt_yes "Run 'gcloud auth application-default login' now?" "Y"; then
    gcloud auth application-default login --project "$GCP_PROJECT_ID"
    if gcloud auth application-default print-access-token >/dev/null 2>&1; then
      return 0
    fi
    echo "Application Default Credentials are still unavailable after login." >&2
  else
    echo "Application Default Credentials are required for Terraform to authenticate." >&2
  fi
  echo "Set the GOOGLE_APPLICATION_CREDENTIALS env var to a service account key or rerun bootstrap after configuring credentials." >&2
  exit 1
}


configure_github_environments() {
  local env_name tf_env_name
  for env_name in staging production; do
    if [[ "$env_name" == "production" ]]; then
      tf_env_name="prod"
    else
      tf_env_name="$env_name"
    fi
    if env_was_skipped "$tf_env_name"; then
      echo "Skipping GitHub environment configuration for $env_name (terraform apply skipped)."
      continue
    fi
    if [[ -z "${TERRAFORM_OUTPUTS_JSON[$tf_env_name]:-}" ]]; then
      echo "Terraform outputs missing for $env_name; run capture_terraform_outputs first." >&2
      continue
    fi
    echo "Updating GitHub environment secrets for $env_name..."
    sync_github_environment "$env_name" "$tf_env_name"
  done
}





load_state

BOOTSTRAP_COMPLETED="${BOOTSTRAP_COMPLETED:-no}"

if [[ ( ! -t 0 || "${WINDOWS_AUTOMATED_SETUP:-0}" == "1" ) && "${INFRA_BOOTSTRAP_ASSUME_DEFAULTS:-0}" != "1" ]]; then
  heading "Infrastructure bootstrap"
  echo "Skipping interactive infrastructure bootstrap (non-interactive environment detected)."
  echo "Run scripts/bootstrap-infra.sh from an interactive shell when you are ready to provision cloud resources."
  exit 0
fi

if [[ "${BOOTSTRAP_COMPLETED:-}" == "yes" ]]; then
  if ! prompt_yes "Infrastructure bootstrap already completed. Re-run anyway?" "N"; then
    echo "Bootstrap already complete. Nothing to do."
    exit 0
  fi
fi

heading "Collect configuration"
prompt_for GCP_PROJECT_ID "Enter GCP project ID" "${GCP_PROJECT_ID:-}"
prompt_for GCP_REGION "Enter default GCP region" "${GCP_REGION:-us-central1}"
prompt_for GITHUB_ORG_REPO "Enter GitHub org/repo (e.g. org/name)" "${GITHUB_ORG_REPO:-}"
if [[ -z "${STAGING_KSA_NAMESPACE:-}" ]]; then
  prompt_for STAGING_KSA_NAMESPACE "Enter staging runtime KSA namespace" "web"
fi
if [[ -z "${STAGING_KSA_NAME:-}" ]]; then
  prompt_for STAGING_KSA_NAME "Enter staging runtime KSA name" "web-sa"
fi
if [[ -z "${PRODUCTION_KSA_NAMESPACE:-}" ]]; then
  prompt_for PRODUCTION_KSA_NAMESPACE "Enter production runtime KSA namespace" "web"
fi
if [[ -z "${PRODUCTION_KSA_NAME:-}" ]]; then
  prompt_for PRODUCTION_KSA_NAME "Enter production runtime KSA name" "web-sa"
fi
write_state

heading "Authenticate CLIs"
if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud CLI is required. Please install it and re-run."
  exit 1
fi

if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "."; then
  echo "No active gcloud authentication found."
  if prompt_yes "Run gcloud auth login now?"; then
    gcloud auth login --project "$GCP_PROJECT_ID"
  else
    echo "gcloud authentication is required."
    exit 1
  fi
fi

ACTIVE_GCLOUD_ACCOUNT="$(gcloud config get-value account 2>/dev/null | tr -d '\r')"
if [[ -z "$ACTIVE_GCLOUD_ACCOUNT" ]]; then
  echo "Unable to determine active gcloud account. Run 'gcloud auth login' and re-run." >&2
  exit 1
fi
ensure_gcloud_project_access

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required. Please install it and re-run."
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated."
  if prompt_yes "Run gh auth login now?"; then
    gh auth login
  else
    echo "GitHub authentication is required."
    exit 1
  fi
fi

heading "Enable foundational GCP APIs"
REQUIRED_APIS=(
  compute.googleapis.com
  container.googleapis.com
  iam.googleapis.com
  cloudresourcemanager.googleapis.com
  cloudbuild.googleapis.com
  artifactregistry.googleapis.com
  secretmanager.googleapis.com
  serviceusage.googleapis.com
  certificatemanager.googleapis.com
  mesh.googleapis.com
  binaryauthorization.googleapis.com
)

ENABLED_APIS="$(gcloud services list --enabled --project "$GCP_PROJECT_ID" --format="value(config.name)")"
for api in "${REQUIRED_APIS[@]}"; do
  if echo "$ENABLED_APIS" | grep -qx "$api"; then
    echo "API $api already enabled."
  else
    echo "Enabling API $api..."
    gcloud services enable "$api" --project "$GCP_PROJECT_ID"
  fi
done

ensure_binary_authorization_attestors

heading "Configure Terraform backend"
prompt_for TERRAFORM_STATE_BUCKET "Enter Terraform state bucket name" "${TERRAFORM_STATE_BUCKET:-${GCP_PROJECT_ID}-tf-state}"
write_state
ensure_gcs_bucket "$TERRAFORM_STATE_BUCKET"
update_backend_file "$ROOT_DIR/infra/terraform/envs/staging/backend.tf" "$TERRAFORM_STATE_BUCKET"
update_backend_file "$ROOT_DIR/infra/terraform/envs/prod/backend.tf" "$TERRAFORM_STATE_BUCKET"

if ! command -v terraform >/dev/null 2>&1; then
  echo "Terraform CLI is required. Please install it and re-run."
  exit 1
fi

ensure_application_default_credentials

heading "Initial Terraform provisioning"
run_terraform_for_env staging
run_terraform_for_env prod

capture_terraform_outputs staging || true
capture_terraform_outputs prod || true
ensure_attestor_signing_permissions
configure_github_environments

BOOTSTRAP_COMPLETED="yes"
write_state

heading "Bootstrap complete"
echo "Core infrastructure prerequisites and Terraform foundations are configured."
if ((${#SKIPPED_APPLY_ENVS[@]} > 0)); then
  echo "Terraform apply was skipped for: ${SKIPPED_APPLY_ENVS[*]}. Re-run scripts/bootstrap-infra.sh to apply when ready."
fi
echo "Next steps:"
echo "  - Review Terraform state in gs://$TERRAFORM_STATE_BUCKET."
echo "  - Verify GitHub environment secrets and variables in the repository settings."
