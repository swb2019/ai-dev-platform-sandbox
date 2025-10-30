#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: scripts/create-binauthz-attestor.sh <staging|production> <gcp-project-id>" >&2
  exit 1
fi

ENV_NAME="$1"
PROJECT_ID="$2"

declare -A DEFAULTS
case "$ENV_NAME" in
  staging)
    LABEL="staging"
    DEFAULTS[attestor_id]="stg-attestor"
    DEFAULTS[note_id]="stg-image-signing"
    DEFAULTS[key_id]="stg-cosign"
    ;;
  production|prod)
    LABEL="production"
    DEFAULTS[attestor_id]="prod-attestor"
    DEFAULTS[note_id]="prod-image-signing"
    DEFAULTS[key_id]="prod-cosign"
    ;;
  *)
    echo "Unknown environment: $ENV_NAME" >&2
    exit 1
    ;;
esac

call_api() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  local response
  if [[ -n "$data" ]]; then
    response=$(curl -sS -X "$method" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$data" "$url" -w "\n%{http_code}")
  else
    response=$(curl -sS -X "$method" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" "$url" -w "\n%{http_code}")
  fi
  API_STATUS="${response##*$'\n'}"
  if [[ "$response" == "$API_STATUS" ]]; then
    API_BODY=""
  else
    API_BODY="${response%$'\n'"$API_STATUS"}"
  fi
}

read -r -p "Enter ${LABEL} attestor ID [${DEFAULTS[attestor_id]}]: " ATTESTOR_ID || true
ATTESTOR_ID="${ATTESTOR_ID:-${DEFAULTS[attestor_id]}}"
read -r -p "Enter ${LABEL} note ID [${DEFAULTS[note_id]}]: " NOTE_ID || true
NOTE_ID="${NOTE_ID:-${DEFAULTS[note_id]}}"

DEFAULT_KEY_PATH="$HOME/.config/cosign/${LABEL}.pub"

read_pubkey_path() {
  local label="$1"
  local default_path="$2"
  local response=""
  if [[ -t 0 && -t 1 ]]; then
    read -r -p "Enter path to ${label} public key file [${default_path}]: " response || true
  else
    printf "Using default %s public key path %s (non-interactive).\n" "$label" "$default_path" >&2
  fi
  response="${response:-$default_path}"
  response="${response/#~/$HOME}"
  echo "$response"
}

ensure_cosign_available() {
  if command -v cosign >/dev/null 2>&1; then
    return
  fi
  echo "Cosign CLI not found. Attempting automatic installation..." >&2
  if command -v apt-get >/dev/null 2>&1; then
    if [[ $EUID -eq 0 ]]; then
      echo "Installing cosign with apt-get (running as root)..." >&2
      if apt-get update >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y cosign >/dev/null 2>&1; then
        echo "Cosign installed via apt." >&2
        return
      fi
      echo "apt-get installation as root failed. Falling back to direct download." >&2
    elif command -v sudo >/dev/null 2>&1; then
      if sudo -n true >/dev/null 2>&1; then
        echo "Installing cosign with sudo apt-get..." >&2
        if sudo -n apt-get update >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive sudo -n apt-get install -y cosign >/dev/null 2>&1; then
          echo "Cosign installed via apt." >&2
          return
        fi
        echo "sudo apt-get installation failed. Falling back to direct download." >&2
      else
        echo "sudo requires an interactive password; skipping apt-get installation." >&2
      fi
    fi
  fi
  local arch
  arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
  case "$arch" in
    amd64|x86_64)
      arch_asset="amd64"
      ;;
    arm64|aarch64)
      arch_asset="arm64"
      ;;
    *)
      echo "Unsupported architecture '$arch'. Install cosign manually and rerun." >&2
      exit 1
      ;;
  esac
  local tmpdir
  tmpdir=$(mktemp -d)
  local asset="cosign-linux-${arch_asset}"
  local url="https://github.com/sigstore/cosign/releases/latest/download/${asset}"
  echo "Downloading cosign binary from ${url}..." >&2
  if ! curl -fsSL -o "$tmpdir/cosign" "$url"; then
    echo "Failed to download cosign binary. Install cosign manually and rerun." >&2
    rm -rf "$tmpdir"
    exit 1
  fi
  chmod +x "$tmpdir/cosign"
  local target_dir="$HOME/.local/bin"
  mkdir -p "$target_dir"
  mv "$tmpdir/cosign" "$target_dir/cosign"
  rm -rf "$tmpdir"
  PATH="$target_dir:$PATH"
  export PATH
  if ! command -v cosign >/dev/null 2>&1; then
    echo "Cosign installation failed. Install it manually and rerun." >&2
    exit 1
  fi
  echo "Cosign installed at $target_dir/cosign." >&2
}

generate_cosign_key() {
  local label="$1"
  local pubkey="$2"
  local key_prefix="${pubkey%.pub}"
  local dir
  dir="$(dirname "$pubkey")"
  mkdir -p "$dir"
  if [[ -f "$pubkey" ]]; then
    return 0
  fi
  ensure_cosign_available
  echo "Generating Cosign key pair for ${label} at ${key_prefix}.{key,pub}..." >&2
  ensure_cosign_available
  local log_file
  log_file="$(mktemp)"
  hash -r
  if ! env COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix "$key_prefix" >"$log_file" 2>&1; then
    cat "$log_file" >&2
    rm -f "$log_file"
    echo "Failed to generate Cosign key pair for ${label}. Ensure the directory is writable or provide an existing key." >&2
    exit 1
  fi
  rm -f "$log_file"
  if [[ ! -f "$pubkey" ]]; then
    echo "Cosign reported success but ${pubkey} is missing. Provide a valid PEM public key." >&2
    exit 1
  fi
}

PUBKEY_FILE="$(read_pubkey_path "$LABEL" "$DEFAULT_KEY_PATH")"
generate_cosign_key "$LABEL" "$PUBKEY_FILE"

read -r -p "Enter ${LABEL} public key ID [${DEFAULTS[key_id]}]: " PUBKEY_ID || true
PUBKEY_ID="${PUBKEY_ID:-${DEFAULTS[key_id]}}"

NOTE_RESOURCE="projects/${PROJECT_ID}/notes/${NOTE_ID}"
ATTESTOR_RESOURCE="projects/${PROJECT_ID}/attestors/${ATTESTOR_ID}"

ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null | tr -d '\r')
if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "Failed to obtain an access token via gcloud. Run 'gcloud auth login' and try again." >&2
  exit 1
fi

call_api GET "https://containeranalysis.googleapis.com/v1/${NOTE_RESOURCE}"
case "$API_STATUS" in
  200) ;;
  404)
    note_payload=$(LABEL_DISPLAY="${LABEL^}" python3 <<'PY'
import json, os
print(json.dumps({
    "kind": "ATTESTATION",
    "attestation": {
        "hint": {
            "humanReadableName": f"{os.environ['LABEL_DISPLAY']} image signing note"
        }
    }
}))
PY
)
    call_api POST "https://containeranalysis.googleapis.com/v1/projects/${PROJECT_ID}/notes?noteId=${NOTE_ID}" "$note_payload"
    if [[ "$API_STATUS" != "200" && "$API_STATUS" != "201" ]]; then
      echo "Failed to create Binary Authorization note ${NOTE_RESOURCE} (status $API_STATUS)." >&2
      if [[ -n "$API_BODY" ]]; then
        echo "$API_BODY" >&2
      fi
      exit 1
    fi
    ;;
  *)
    echo "Unable to access Binary Authorization note ${NOTE_RESOURCE} (status $API_STATUS)." >&2
    if [[ -n "$API_BODY" ]]; then
      echo "$API_BODY" >&2
    fi
    exit 1
    ;;
esac

existing_attestor_json=$(gcloud container binauthz attestors describe "$ATTESTOR_ID" --project "$PROJECT_ID" --format=json 2>/dev/null || true)
if [[ -z "$existing_attestor_json" ]]; then
  echo "Creating Binary Authorization attestor ${ATTESTOR_RESOURCE}..." >&2
  gcloud container binauthz attestors create "$ATTESTOR_ID" \
    --project "$PROJECT_ID" \
    --attestation-authority-note="$NOTE_RESOURCE" \
    --attestation-authority-note-project="$PROJECT_ID" >/dev/null
  existing_attestor_json=$(gcloud container binauthz attestors describe "$ATTESTOR_ID" --project "$PROJECT_ID" --format=json)
fi

if ! ATTESTOR_JSON="$existing_attestor_json" TARGET_KEY="$PUBKEY_ID" python3 <<'PY'
import json, os, sys
attestor = json.loads(os.environ.get('ATTESTOR_JSON') or '{}')
target = os.environ['TARGET_KEY']
keys = attestor.get('userOwnedGrafeasNote', {}).get('publicKeys', [])
if any(key.get('id') == target for key in keys):
    sys.exit(0)
sys.exit(1)
PY
then
  echo "Adding public key $PUBKEY_ID to attestor $ATTESTOR_RESOURCE..." >&2
  gcloud container binauthz attestors public-keys add \
    --attestor "$ATTESTOR_ID" \
    --project "$PROJECT_ID" \
    --pkix-public-key-file "$PUBKEY_FILE" \
    --pkix-public-key-algorithm ecdsa-p256-sha256 \
    --public-key-id-override "$PUBKEY_ID" >/dev/null
  existing_attestor_json=$(gcloud container binauthz attestors describe "$ATTESTOR_ID" --project "$PROJECT_ID" --format=json)
fi

printf "%s\n" "$ATTESTOR_RESOURCE"
