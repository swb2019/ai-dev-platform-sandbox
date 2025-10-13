#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKER_FILE="$ROOT_DIR/.onboarding_complete"
NON_INTERACTIVE=0
USE_INFISICAL=0
PNPM_INSTALL_TIMEOUT="${PNPM_INSTALL_TIMEOUT:-900}"

heading() {
  printf "\n==> %s\n" "$1"
}

prompt_yes() {
  local prompt="${1:-Continue?}" default="${2:-Y}" reply normalized_default
  normalized_default="${default:-Y}"
  normalized_default="${normalized_default:0:1}"
  case "${normalized_default}" in
    [YyNn]) ;;
    *) normalized_default="Y" ;;
  esac

  if [[ ! -t 0 || ! -t 1 ]]; then
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

require_command() {
  local bin="$1" install_hint="${2:-}"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Required tool '$bin' is not installed or not on PATH."
    [[ -n "$install_hint" ]] && echo "$install_hint"
    exit 1
  fi
}

infisical_installed() {
  command -v infisical >/dev/null 2>&1
}

can_reach_host() {
  local host="${1:-}"
  if [[ -z "$host" ]]; then
    return 1
  fi
  if command -v getent >/dev/null 2>&1; then
    if getent hosts "$host" >/dev/null 2>&1; then
      return 0
    fi
  fi
  if command -v nslookup >/dev/null 2>&1; then
    if nslookup -timeout=3 "$host" >/dev/null 2>&1; then
      return 0
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    local url
    if [[ "$host" == http*://* ]]; then
      url="$host"
    else
      url="https://$host"
    fi
    if curl -sS --head --max-time 5 --connect-timeout 3 "$url" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

install_infisical() {
  heading "Installing Infisical CLI"
  if infisical_installed; then
    echo "Infisical CLI already installed."
    return 0
  fi

  local registry_host=registry.npmjs.org
  local installer_host=cli.infisical.com
  local registry_available=0
  local installer_available=0

  if can_reach_host "$registry_host"; then
    registry_available=1
  else
    echo "registry.npmjs.org not reachable; skipping npm-based Infisical install."
  fi

  if can_reach_host "$installer_host"; then
    installer_available=1
  else
    echo "cli.infisical.com not reachable; skipping curl-based Infisical install."
  fi

  if (( !registry_available && !installer_available )); then
    echo "Infisical CLI network sources unavailable; continuing without installation."
    return 1
  fi

  local install_success=0

  if (( registry_available )); then
    local npm_cmd=(npm install -g @infisical/cli)
    if command -v timeout >/dev/null 2>&1; then
      npm_cmd=(timeout 45 "${npm_cmd[@]}")
    fi
    if "${npm_cmd[@]}"; then
      install_success=1
      [[ -d "/home/user/.npm-global/bin" ]] && export PATH="/home/user/.npm-global/bin:$PATH"
    else
      echo "npm install for Infisical CLI failed; will try curl fallback."
    fi
  fi

  if (( !install_success && installer_available )); then
    if command -v timeout >/dev/null 2>&1; then
      if timeout 45 curl -sSfL https://cli.infisical.com/install.sh | sh; then
        install_success=1
      else
        echo "Curl-based Infisical installation failed."
      fi
    else
      if curl -sSfL https://cli.infisical.com/install.sh | sh; then
        install_success=1
      else
        echo "Curl-based Infisical installation failed."
      fi
    fi
  fi

  if (( install_success )); then
    [[ -d "/home/user/.infisical/bin" ]] && export PATH="/home/user/.infisical/bin:$PATH"
    if infisical_installed; then
      return 0
    fi
  fi

  if (( NON_INTERACTIVE )); then
    echo "Unable to install Infisical CLI automatically; continuing without it."
    return 1
  fi
  echo "Unable to install Infisical CLI."
  exit 1
}

ensure_gh_auth() {
  heading "GitHub CLI authentication"
  if ! command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI not available; skipping authentication."
    return 0
  fi
  if gh auth status >/dev/null 2>&1; then
    echo "GitHub CLI already authenticated."
    return 0
  fi
  if [[ -n "${GH_TOKEN:-}" ]]; then
    if printf '%s\n' "$GH_TOKEN" | gh auth login --with-token >/dev/null 2>&1; then
      gh auth status >/dev/null 2>&1 && { echo "Authenticated GitHub CLI using GH_TOKEN."; return 0; }
    fi
    echo "Failed to authenticate GitHub CLI using GH_TOKEN; falling back." >&2
  fi
  if (( NON_INTERACTIVE )); then
    echo "GitHub CLI is not authenticated. Set GH_TOKEN or run 'gh auth login' after attaching to the container."
    return 0
  fi
  gh auth login
  gh auth status >/dev/null 2>&1 || { echo "GitHub authentication failed."; exit 1; }
}

infisical_authenticated() {
  infisical whoami >/dev/null 2>&1 || infisical user get token --silent --plain >/dev/null 2>&1
}

ensure_infisical_auth() {
  if infisical_authenticated; then
    USE_INFISICAL=1
    echo "Infisical CLI already authenticated."
    return 0
  fi
  if [[ -n "${INFISICAL_TOKEN:-}" ]]; then
    export INFISICAL_TOKEN
    USE_INFISICAL=1
    echo "Using INFISICAL_TOKEN from environment."
    return 0
  fi
  if (( NON_INTERACTIVE )); then
    echo "Infisical CLI is not authenticated. Set INFISICAL_TOKEN or run 'infisical login' later; continuing without Infisical-managed secrets."
    USE_INFISICAL=0
    return 1
  fi
  echo "Infisical CLI is not authenticated."
  infisical login
  if infisical_authenticated; then
    USE_INFISICAL=1
    return 0
  fi
  echo "Infisical authentication failed."
  return 1
}

can_reach_npm_registry() {
  if command -v getent >/dev/null 2>&1; then
    if getent hosts registry.npmjs.org >/dev/null 2>&1; then
      return 0
    fi
  fi
  if command -v nslookup >/dev/null 2>&1; then
    if nslookup -timeout=3 registry.npmjs.org >/dev/null 2>&1; then
      return 0
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    if curl -sS --head --max-time 5 --connect-timeout 3 https://registry.npmjs.org >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}
run_dependency_install() {
  heading "Install workspace dependencies"
  require_command pnpm "Install pnpm@9 before continuing."
  export PNPM_CONFIG_CONFIRM_MODULES_DELETION=false
  if ! can_reach_npm_registry; then
    if [[ -d "node_modules" ]]; then
      echo "registry.npmjs.org not reachable; using existing node_modules without reinstall."
      return 0
    fi
    echo "registry.npmjs.org not reachable; skipping pnpm install to avoid hanging."
    return 0
  fi
  if (( USE_INFISICAL )); then
    local runner=(infisical run -- pnpm install --frozen-lockfile)
    if command -v timeout >/dev/null 2>&1; then
      runner=(timeout "$PNPM_INSTALL_TIMEOUT" "${runner[@]}")
    fi
    if ! "${runner[@]}"; then
      echo "Infisical-managed install failed or timed out after ${PNPM_INSTALL_TIMEOUT}s; retrying without Infisical."
      pnpm install --frozen-lockfile
    fi
  else
    pnpm install --frozen-lockfile
  fi
}
install_codex() {
  heading "Installing Codex CLI"
  if command -v codex >/dev/null 2>&1; then
    echo "Codex CLI already installed."
    return 0
  fi

  local bundled_codex="$ROOT_DIR/tmp/cursor-tools/codex"
  local target="$HOME/.npm-global/bin/codex"

  if [[ -f "$bundled_codex" ]]; then
    mkdir -p "$(dirname "$target")"
    cp "$bundled_codex" "$target"
    chmod +x "$target"
    if command -v codex >/dev/null 2>&1; then
      echo "Codex CLI installed from bundled binary."
      return 0
    fi
  fi

  echo "Codex CLI binary not found. Copy tmp/cursor-tools/codex before running onboard." >&2
  return 1
}

configure_codex_agent_defaults() {
  heading "Configuring Codex agent defaults"
  local cursor_config="$HOME/.cursor/cli-config.json"
  mkdir -p "$(dirname "$cursor_config")"
  python3 - "$cursor_config" <<'PYCFG'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
if config_path.exists():
    try:
        data = json.loads(config_path.read_text())
    except json.JSONDecodeError:
        data = {}
else:
    data = {}

data.setdefault("version", 1)
data["hasChangedDefaultModel"] = True

permissions = data.setdefault("permissions", {})
permissions["allow"] = ["*"]
permissions["deny"] = []

data["approvalMode"] = "never"

sandbox = data.setdefault("sandbox", {})
sandbox["mode"] = "danger-full-access"
sandbox["networkAccess"] = "enabled"

network = data.setdefault("network", {})
network["useHttp1ForAgent"] = False

config_path.write_text(json.dumps(data, indent=2) + "\n")
PYCFG

  local codex_dir="$HOME/.codex"
  local codex_config="$codex_dir/config.toml"
  mkdir -p "$codex_dir"
  cat > "$codex_config" <<'PYCFG'
model = "gpt-5-codex"
model_reasoning_effort = "high"
approval_policy = "never"

[sandbox_policy]
mode = "danger-full-access"
network_access = "enabled"
PYCFG
}


collect_editor_cli() {
  local -n _candidates=$1
  _candidates=()
  if command -v code >/dev/null 2>&1; then
    _candidates+=(code)
  fi
  if command -v code-server >/dev/null 2>&1; then
    _candidates+=(code-server)
  fi

  local server_root="${VSCODE_AGENT_FOLDER:-$HOME/.vscode-server}"
  if [[ -d "$server_root/bin" ]]; then
    while IFS= read -r candidate; do
      _candidates+=("$candidate")
    done < <(find "$server_root/bin" -maxdepth 3 -type f \( -name code -o -name code-server \) 2>/dev/null)
  fi
}

install_marketplace_extension() {
  local label="$1" extension="$2"
  local -a cli_candidates=()
  collect_editor_cli cli_candidates

  local cli
  for cli in "${cli_candidates[@]}"; do
    if "$cli" --install-extension "$extension" --force >/dev/null 2>&1; then
      echo "$label extension installed via $cli marketplace (latest available)."
      return 0
    fi
  done
  return 1
}

install_vsix_extension() {
  local label="$1" vsix_path="$2"
  if [[ ! -f "$vsix_path" ]]; then
    echo "$label VSIX not found at $vsix_path; skipping."
    return 1
  fi

  local -a cli_candidates=()
  collect_editor_cli cli_candidates

  local server_root="${VSCODE_AGENT_FOLDER:-$HOME/.vscode-server}"
  local installed=0
  for cli in "${cli_candidates[@]}"; do
    if "$cli" --install-extension "$vsix_path" --force >/dev/null 2>&1; then
      echo "$label VSIX installed via $cli."
      installed=1
      break
    fi
  done

  if (( !installed )); then
    local ext_cache="$server_root/extensions"
    mkdir -p "$ext_cache"

    local metadata
    if metadata=$(python3 -c 'import sys, zipfile, xml.etree.ElementTree as ET
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
print(identity.get("Version", "0.0.0"))' "$vsix_path" 2>/dev/null); then
      local publisher id version
      publisher=$(printf '%s
' "$metadata" | sed -n '1p')
      id=$(printf '%s
' "$metadata" | sed -n '2p')
      version=$(printf '%s
' "$metadata" | sed -n '3p')

      if [[ -n "$publisher" && -n "$id" && -n "$version" ]]; then
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
        relative = info.filename[len("extension/"): ]
        if not relative:
            continue
        target = os.path.join(dst, relative)
        if info.is_dir():
            os.makedirs(target, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with zf.open(info) as source, open(target, "wb") as dest:
                dest.write(source.read())' "$vsix_path" "$ext_dir" >/dev/null 2>&1; then
          echo "$label VSIX unpacked to $ext_dir for offline install."
          installed=1
        fi
      fi
    fi

    if (( !installed )); then
      cp "$vsix_path" "$ext_cache/$(basename "$vsix_path")"
      echo "Stored $label VSIX at $ext_cache; install manually once an editor attaches."
      return 1
    fi
  fi

  return 0
}

install_editor_extensions() {
  heading "Install AI editor extensions"
  local vsix_dir="$ROOT_DIR/tmp/cursor-tools"
  local installed_any=0
  local failures=0

  if install_marketplace_extension "OpenAI Codex" "openai.chatgpt"; then
    installed_any=1
  elif install_vsix_extension "OpenAI Codex" "$vsix_dir/openai-chatgpt.vsix"; then
    installed_any=1
  else
    ((failures++))
  fi

  if install_marketplace_extension "Claude Code" "anthropic.claude-code"; then
    installed_any=1
  elif install_vsix_extension "Claude Code" "$vsix_dir/anthropic-claude-code.vsix"; then
    installed_any=1
  else
    ((failures++))
  fi

  if (( failures > 0 )); then
    if (( installed_any )); then
      echo "Some AI editor extensions could not be installed automatically; see messages above."
    else
      echo "AI editor extensions were not installed automatically; cached VSIX files can be installed manually."
    fi
  fi

  return 0
}

install_claude_cli() {
  if command -v claude >/dev/null 2>&1; then
    return 0
  fi

  local -a search_roots=(
    "$HOME/.cursor-server/extensions"
    "$HOME/.vscode-server/extensions"
    "$HOME/.vscode/extensions"
  )
  local cli_path=""

  for root in "${search_roots[@]}"; do
    if [[ ! -d "$root" ]]; then
      continue
    fi
    local latest
    latest=$(ls -d "$root"/anthropic.claude-code-* 2>/dev/null | sort -V | tail -n 1 || true)
    if [[ -z "$latest" ]]; then
      continue
    fi
    if [[ -f "$latest/resources/claude-code/cli.js" ]]; then
      cli_path="$latest/resources/claude-code/cli.js"
      break
    fi
  done

  if [[ -z "$cli_path" ]]; then
    return 1
  fi

  chmod +x "$cli_path"

  local -a target_bins=(
    "$HOME/.npm-global/bin"
    "$HOME/.local/bin"
    "/usr/local/share/npm-global/bin"
  )

  local linked=1
  for bin_dir in "${target_bins[@]}"; do
    mkdir -p "$bin_dir"
    ln -sf "$cli_path" "$bin_dir/claude"
    if PATH="$bin_dir:$PATH" command -v claude >/dev/null 2>&1; then
      linked=0
    fi
  done

  return $linked
}

guide_github_ssh() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "GitHub SSH setup guidance skipped (non-interactive session). Run scripts/onboard.sh from a terminal to walk through Git access." >&2
    return 0
  fi

  heading "GitHub SSH access"

  local ssh_dir="$HOME/.ssh"
  local default_key="$ssh_dir/id_ed25519.pub"
  local alt_key="$ssh_dir/id_rsa.pub"
  local generated_ssh_key=0

  mkdir -p "$ssh_dir"

  if [[ ! -f "$default_key" && ! -f "$alt_key" ]]; then
    echo "No SSH public key detected. GitHub pushes over SSH will fail until a key is registered."
    if prompt_yes "Generate a new ed25519 SSH key for GitHub now?" "Y"; then
      local default_label="ai-dev-platform@local"
      read -r -p "Enter an email or label for the key [$default_label]: " email || true
      email="${email:-$default_label}"
      if ssh-keygen -t ed25519 -C "$email" -f "$ssh_dir/id_ed25519"; then
        echo "Created SSH key at $ssh_dir/id_ed25519.pub"
        generated_ssh_key=1
      else
        echo "ssh-keygen failed; you can rerun scripts/onboard.sh after installing OpenSSH." >&2
        return 1
      fi
    else
      echo "Skipping SSH key generation. Use 'ssh-keygen -t ed25519 -C "you@example.com"' later."
    fi
  else
    echo "Existing SSH key detected: ${default_key:-$alt_key}"
  fi

  local key_to_show=""
  if [[ -f "$default_key" ]]; then
    key_to_show="$default_key"
  elif [[ -f "$alt_key" ]]; then
    key_to_show="$alt_key"
  fi

  if [[ -n "$key_to_show" ]]; then
    if prompt_yes "Display your public key so you can copy it to GitHub?" "Y"; then
      echo "\n----- COPY BELOW INTO https://github.com/settings/ssh/new -----"
      cat "$key_to_show"
      echo "----- END COPY -----\n"
    else
      echo "Public key located at $key_to_show"
    fi

    local offer_upload_via_gh=0
    local offer_upload_via_pat=0

    if (( generated_ssh_key )); then
      offer_upload_via_pat=1
    else
      if prompt_yes "Upload the key to GitHub using the GitHub CLI (gh)?" "N"; then
        offer_upload_via_gh=1
      elif prompt_yes "Upload the key to GitHub using a Personal Access Token?" "N"; then
        offer_upload_via_pat=1
      fi
    fi

    if (( offer_upload_via_gh )); then
      if ! command -v gh >/dev/null 2>&1; then
        echo "GitHub CLI (gh) not available; install it and rerun this step or choose PAT upload." >&2
      else
        echo "Ensuring gh authentication includes 'admin:public_key' scope..." >&2
        if ! gh auth status >/dev/null 2>&1; then
          cat <<'GHLOGIN'
'gh auth login' will open the GitHub device/browser flow. When prompted:
  1. Select GitHub.com and HTTPS.
  2. Choose your preferred auth method (browser or device) and finish the login.
  3. Return here once gh reports success.
GHLOGIN
          gh auth login || { echo "gh auth login failed; continuing without CLI upload." >&2; }
        fi
        if gh auth status >/dev/null 2>&1; then
          cat <<'GHREFRESH'
Requesting 'admin:public_key' scope. If a device code or browser prompt appears, approve the request and return here.
GHREFRESH
          if ! gh auth refresh --scopes admin:public_key -h github.com; then
            echo "gh auth refresh did not complete; falling back to PAT upload." >&2
            offer_upload_via_pat=1
          else
            local key_title_default="ai-dev-platform-$(date +%Y%m%d)"
            read -r -p "GitHub key title [$key_title_default]: " key_title || true
            key_title="${key_title:-$key_title_default}"
            if gh ssh-key add "$key_to_show" --title "$key_title"; then
              echo "GitHub accepted key '$key_title' via gh CLI."
            else
              echo "gh ssh-key add failed; you can retry or use the PAT flow." >&2
              offer_upload_via_pat=1
            fi
          fi
        fi
      fi
    fi

    if (( offer_upload_via_pat )); then
      local key_title_default="ai-dev-platform-$(date +%Y%m%d)"
      read -r -p "GitHub key title [$key_title_default]: " key_title || true
      key_title="${key_title:-$key_title_default}"
      echo "Enter a GitHub Personal Access Token with 'admin:public_key' scope. Input is hidden." >&2
      read -r -s -p "PAT: " github_pat || true
      echo
      if [[ -z "$github_pat" ]]; then
        echo "No token entered; skipping API upload." >&2
      else
        if ! command -v jq >/dev/null 2>&1; then
          echo "jq is required for automatic upload; install it and rerun this step." >&2
        else
          local payload
          payload=$(jq -n --arg title "$key_title" --arg key "$(cat "$key_to_show")" '{title:$title, key:$key}')
          local response
          response=$(curl -sS -X POST \
            -H "Authorization: token $github_pat" \
            -H "Accept: application/vnd.github+json" \
            https://api.github.com/user/keys \
            -d "$payload")
          if echo "$response" | jq -e '.id' >/dev/null 2>&1; then
            echo "GitHub accepted key '$key_title'."
          else
            echo "Failed to upload key via API. Response:" >&2
            echo "$response" >&2
          fi
        fi
        unset github_pat
      fi
    fi

    cat <<'INSTRUCTIONS'
Next steps:
  1. Open https://github.com/settings/ssh/new in your browser.
  2. Paste the public key above, give it a name (e.g., "Dev machine"), and save.
  3. Test the connection with: ssh -T git@github.com

If GitHub replies "successfully authenticated" you can push via git@github.com:...
INSTRUCTIONS

    if prompt_yes "Test GitHub SSH connectivity now?" "Y"; then
      ssh -T git@github.com || true
    fi
  else
    echo "No SSH key available yet; GitHub setup skipped."
  fi
}


offer_configure_github_envs() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "GitHub environment configuration skipped (non-interactive session). Run ./scripts/configure-github-env.sh staging/prod later." >&2
    return 0
  fi

  local configure_script="$ROOT_DIR/scripts/configure-github-env.sh"
  if [[ ! -x "$configure_script" ]]; then
    echo "Environment script $configure_script not found or not executable; run it manually when available." >&2
    return 0
  fi

  heading "GitHub environment secrets"
  echo "Ensure 'gh auth login' is completed before continuing."

  if prompt_yes "Configure the staging environment now?" "Y"; then
    if ! bash "$configure_script" staging; then
      echo "Staging environment configuration failed; rerun ./scripts/configure-github-env.sh staging when ready." >&2
    fi
  else
    echo "Skipped staging environment secret setup."
  fi

  if prompt_yes "Configure the production environment now?" "N"; then
    if ! bash "$configure_script" prod; then
      echo "Production environment configuration failed; rerun ./scripts/configure-github-env.sh prod when ready." >&2
    fi
  else
    echo "Skipped production environment secret setup."
  fi
}

ensure_agent_extensions() {
  [[ -d "$HOME/.npm-global/bin" ]] && export PATH="$HOME/.npm-global/bin:$PATH"
  if ! install_codex; then
    echo "Codex CLI setup skipped (provide tmp/cursor-tools/codex before rerunning)."
  fi
  configure_codex_agent_defaults
  if ! install_editor_extensions; then
    echo "AI editor extensions were not installed automatically; cached VSIX files are available in tmp/cursor-tools."
  fi
  if ! install_claude_cli; then
    echo "Claude CLI not linked; install the extension via VS Code / Cursor and re-run onboarding."
  fi
  return 0
}

install_playwright() {
  heading "Playwright browsers"
  if ! command -v pnpm >/dev/null 2>&1; then
    echo "pnpm not available; skipping Playwright installation."
    return
  fi

  local cmd=(pnpm --filter @ai-dev-platform/web exec playwright install)
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    cmd+=(--with-deps)
  else
    echo "Skipping Playwright system dependency install (sudo without passwordless access unavailable)."
  fi

  if ! "${cmd[@]}"; then
    echo "Playwright installation failed. Re-run: ${cmd[*]}"
  fi
}

if [[ ! -t 0 || ! -t 1 ]]; then
  NON_INTERACTIVE=1
  heading "Onboarding"
  printf "Non-interactive postCreate detected; running automated onboarding steps.\n"
else
  heading "Onboarding"
  printf "Interactive onboarding session detected.\n"
fi

if [[ -f "$MARKER_FILE" ]]; then
  heading "Onboarding"
  printf "Onboarding already complete.\n"
  ensure_agent_extensions
  guide_github_ssh
  offer_configure_github_envs
  exit 0
fi

cd "$ROOT_DIR"

ensure_gh_auth

[[ -d "$HOME/.npm-global/bin" ]] && export PATH="$HOME/.npm-global/bin:$PATH"
[[ -d "$HOME/.infisical/bin" ]] && export PATH="$HOME/.infisical/bin:$PATH"

if ! install_infisical; then
  USE_INFISICAL=0
fi
ensure_agent_extensions
if ! ensure_infisical_auth; then
  echo "Skipping Infisical-backed install for now."
fi
run_dependency_install
install_playwright
guide_github_ssh
offer_configure_github_envs

heading "Finalize onboarding"
touch "$MARKER_FILE"
printf "Onboarding complete!\n"
