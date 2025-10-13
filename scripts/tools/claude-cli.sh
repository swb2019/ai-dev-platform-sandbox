#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
Claude Code CLI helper

This helper opens the Claude Code extension in your connected editor session.
It uses your existing Anthropic subscription; no API tokens are required.

Usage:
  claude                # open Claude Code in the active VS Code window
  claude --help         # show this message

Tips:
  - Start VS Code / Cursor in this workspace and sign in to Claude Code.
  - The helper will try common CLI entry points (code, code-server).
  - If no editor is reachable, instructions will be printed instead.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_help
  exit 0
fi

candidates=(code code-insiders code-server)

if [[ -n "${VSCODE_AGENT_FOLDER:-}" ]]; then
  while IFS= read -r candidate; do
    candidates+=("$candidate")
  done < <(find "$VSCODE_AGENT_FOLDER/bin" -maxdepth 2 -type f \( -name 'code' -o -name 'code-server' \) 2>/dev/null)
fi

for candidate in "${candidates[@]}"; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" --command claude-vscode.window.open >/dev/null 2>&1; then
      exit 0
    fi
    if "$candidate" --command claude-vscode.sidebar.open >/dev/null 2>&1; then
      exit 0
    fi
  fi
done

cat <<'INFO'
Claude Code extension not reachable via command line.
Open your editor manually and launch the Claude sidebar (View > Claude).
INFO

exit 0
