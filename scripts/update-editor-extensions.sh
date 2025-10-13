#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VSIX_DIR="$ROOT_DIR/tmp/cursor-tools"
LOCK_FILE="$ROOT_DIR/config/editor-extensions.lock.json"
mkdir -p "$(dirname "$LOCK_FILE")"

EXT_IDS=("openai.chatgpt" "anthropic.claude-code")
EXT_LABELS=("OpenAI Codex" "Claude Code")
EXT_VSIX=("$VSIX_DIR/openai-chatgpt.vsix" "$VSIX_DIR/anthropic-claude-code.vsix")

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

install_from_marketplace() {
  local extension="$1" label="$2" success=0
  local -a cli=()
  collect_editor_cli cli
  if (( ${#cli[@]} == 0 )); then
    return 1
  fi
  local tool
  for tool in "${cli[@]}"; do
    if "$tool" --install-extension "$extension" --force >/dev/null 2>&1; then
      echo "$label updated via $tool marketplace."
      success=1
    else
      echo "$label marketplace install failed via $tool." >&2
    fi
  done
  (( success ))
}

install_from_vsix() {
  local vsix="$1" label="$2"
  local -a cli=()
  collect_editor_cli cli
  local tool
  for tool in "${cli[@]}"; do
    if "$tool" --install-extension "$vsix" --force >/dev/null 2>&1; then
      echo "$label installed via $tool (VSIX fallback)."
      return 0
    fi
  done
  # fallback to unpack cache for manual install
  local server_root="${VSCODE_AGENT_FOLDER:-$HOME/.vscode-server}"
  local ext_cache="$server_root/extensions"
  mkdir -p "$ext_cache"
  if [[ -f "$vsix" ]]; then
    local metadata
    metadata=$(python3 -c 'import sys, zipfile, xml.etree.ElementTree as ET
path = sys.argv[1]
with zipfile.ZipFile(path) as zf:
    manifest = zf.read("extension.vsixmanifest")
root = ET.fromstring(manifest)
ns = {"vs": "http://schemas.microsoft.com/developer/vsx-schema/2011"}
identity = root.find(".//vs:Identity", ns)
if identity is None:
    raise SystemExit(1)
print(identity.get("Publisher", "publisher"))
print(identity.get("Id", "extension"))
print(identity.get("Version", "0.0.0"))' "$vsix" 2>/dev/null) || return 1
    local publisher id version
    publisher=$(printf '%s
' "$metadata" | sed -n '1p')
    id=$(printf '%s
' "$metadata" | sed -n '2p')
    version=$(printf '%s
' "$metadata" | sed -n '3p')
    local ext_dir="$ext_cache/${publisher}.${id}-${version}"
    rm -rf "$ext_dir"
    mkdir -p "$ext_dir"
    if python3 -c 'import os, sys, zipfile
src = sys.argv[1]
dst = sys.argv[2]
with zipfile.ZipFile(src) as zf:
    for info in zf.infolist():
        if not info.filename.startswith("extension/"):
            continue
        relative = info.filename[len("extension/"):]
        if not relative:
            continue
        target = os.path.join(dst, relative)
        if info.is_dir():
            os.makedirs(target, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with zf.open(info) as source, open(target, "wb") as dest:
                dest.write(source.read())' "$vsix" "$ext_dir" >/dev/null 2>&1; then
      echo "$label unpacked to $ext_dir (manual fallback)."
      return 0
    fi
  fi
  return 1
}

record_extension() {
  local id="$1" version="$2" source="$3"
  EXT_RECORD_IDS+=("$id")
  EXT_RECORD_VERSIONS+=("$version")
  EXT_RECORD_SOURCES+=("$source")
}

EXT_RECORD_IDS=()
EXT_RECORD_VERSIONS=()
EXT_RECORD_SOURCES=()

for i in "${!EXT_IDS[@]}"; do
  extension="${EXT_IDS[$i]}"
  label="${EXT_LABELS[$i]}"
  vsix="${EXT_VSIX[$i]}"
  source=""
  version=""

  if install_from_marketplace "$extension" "$label"; then
    version=$(get_extension_version_cli "$extension" || true)
    source="marketplace"
  fi

  if [[ -z "$version" ]]; then
    if install_from_vsix "$vsix" "$label"; then
      version=$(extract_vsix_version "$vsix")
      source=${source:-vsix}
    fi
  fi

  if [[ -z "$version" ]]; then
    echo "Unable to determine version for $label ($extension)." >&2
    exit 1
  fi

  record_extension "$extension" "$version" "$source"
done

EXT_KEYS=$(printf "%s " "${EXT_RECORD_IDS[@]}")
EXT_VALUES=$(printf "%s " "${EXT_RECORD_VERSIONS[@]}")
EXT_SOURCES=$(printf "%s " "${EXT_RECORD_SOURCES[@]}")
export EXT_KEYS EXT_VALUES EXT_SOURCES

python3 - "$LOCK_FILE" <<'PY'
import json, os, sys
path = sys.argv[1]
keys = os.environ["EXT_KEYS"].split(',') if os.environ.get("EXT_KEYS") else []
values = os.environ["EXT_VALUES"].split(',') if os.environ.get("EXT_VALUES") else []
sources = os.environ["EXT_SOURCES"].split(',') if os.environ.get("EXT_SOURCES") else []
extensions = [
    {"id": k, "version": v, "source": s or "unknown"}
    for k, v, s in zip(keys, values, sources)
]
data = {
    "generatedAt": __import__("datetime").datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
    "extensions": extensions,
}
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

echo "Updated $LOCK_FILE"
echo "Editor extension update process finished."
