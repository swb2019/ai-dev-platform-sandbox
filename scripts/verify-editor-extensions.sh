#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VSIX_DIR="$ROOT_DIR/tmp/cursor-tools"
LOCK_FILE="$ROOT_DIR/config/editor-extensions.lock.json"
STRICT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=1
      shift
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: ./scripts/verify-editor-extensions.sh [--strict]

Validate that installed editor extensions match the versions recorded in
config/editor-extensions.lock.json. With --strict, the script fails if
versions cannot be determined.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$LOCK_FILE" ]]; then
  echo "Lock file $LOCK_FILE not found. Run ./scripts/update-editor-extensions.sh first." >&2
  exit 1
fi

collect_editor_cli() {
  local -n _out=$1
  _out=()
  if command -v code >/dev/null 2>&1; then
    _out+=(code)
  fi
  if command -v code-server >/dev/null 2>&1; then
    _out+=(code-server)
  fi

  local server_root="${VSCODE_AGENT_FOLDER:-$HOME/.vscode-server}"
  if [[ -d "$server_root/bin" ]]; then
    while IFS= read -r candidate; do
      _out+=("$candidate")
    done < <(find "$server_root/bin" -maxdepth 3 -type f \( -name code -o -name code-server \) 2>/dev/null)
  fi
}

extract_vsix_version() {
  local vsix="$1"
  if [[ ! -f "$vsix" ]]; then
    return 1
  fi
  python3 - "$vsix" <<'PY'
import json, sys, zipfile
path = sys.argv[1]
with zipfile.ZipFile(path) as zf:
    data = json.loads(zf.read("extension/package.json"))
print(data.get("version", ""))
PY
}

get_extension_version_cli() {
  local extension="$1" tool
  local -a cli=()
  collect_editor_cli cli
  for tool in "${cli[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      continue
    fi
    local line
    line=$("$tool" --list-extensions --show-versions | awk -v ext="$extension" '$0 ~ ext {print $0; exit}') || true
    if [[ -n "${line:-}" ]]; then
      echo "${line##*@}"
      return 0
    fi
  done
  return 1
}

resolve_version() {
  local extension="$1" vsix="$2"
  local version=""
  version=$(get_extension_version_cli "$extension" || true)
  if [[ -z "$version" ]]; then
    version=$(extract_vsix_version "$vsix" || true)
  fi
  echo "$version"
}

mapfile -t IDS < <(jq -r '.extensions[].id' "$LOCK_FILE")
mapfile -t EXPECTED_VERSIONS < <(jq -r '.extensions[].version' "$LOCK_FILE")
mapfile -t SOURCES < <(jq -r '.extensions[].source' "$LOCK_FILE")

status=0

for idx in "${!IDS[@]}"; do
  extension="${IDS[$idx]}"
  expected="${EXPECTED_VERSIONS[$idx]}"
  source="${SOURCES[$idx]}"
  case "$extension" in
    openai.chatgpt)
      vsix="$VSIX_DIR/openai-chatgpt.vsix"
      ;;
    anthropic.claude-code)
      vsix="$VSIX_DIR/anthropic-claude-code.vsix"
      ;;
    *)
      vsix=""
      ;;
  esac

  actual=$(resolve_version "$extension" "$vsix")
  if [[ -z "$actual" ]]; then
    echo "Unable to determine installed version for $extension." >&2
    if (( STRICT )); then
      exit 1
    fi
    continue
  fi

  if [[ "$actual" != "$expected" ]]; then
    echo "Mismatch for $extension: expected $expected (${source:-unknown}), found $actual" >&2
    status=1
  else
    echo "$extension version OK ($actual)."
  fi

done

exit $status
