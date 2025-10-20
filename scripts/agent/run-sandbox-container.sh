#!/usr/bin/env bash
set -euo pipefail

# Launches an ephemeral Docker container with tight security settings for agent execution.
# The container receives a bind-mounted project workspace and no host platform files.

usage() {
  cat <<'USAGE'
Usage: scripts/agent/run-sandbox-container.sh --workspace PATH [options]

Options:
  --workspace PATH   Required. Path to a project workspace created via create-project-workspace.sh
  --image IMAGE      Container image to use (default: node:20-bullseye)
  --memory SIZE      Memory limit for the container (default: 2g)
  --cpus COUNT       CPU limit (default: 2)
  --network MODE     Docker network mode (default: none)
  --name NAME        Optional container name
  --with-network     Enable default Docker networking instead of 'none'
  --allow-non-sandbox Allow running on directories without a .platform-sandbox marker (not recommended)
  --help             Show this help

Example:
  scripts/agent/run-sandbox-container.sh --workspace ../project-workspaces/demo
USAGE
}

WORKSPACE=""
IMAGE="node:20-bullseye"
MEMORY_LIMIT="2g"
CPU_LIMIT="2"
NETWORK_MODE="none"
CONTAINER_NAME=""
ALLOW_NON_SANDBOX=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      WORKSPACE="$2"; shift 2 ;;
    --image)
      IMAGE="$2"; shift 2 ;;
    --memory)
      MEMORY_LIMIT="$2"; shift 2 ;;
    --cpus)
      CPU_LIMIT="$2"; shift 2 ;;
    --network)
      NETWORK_MODE="$2"; shift 2 ;;
    --name)
      CONTAINER_NAME="$2"; shift 2 ;;
    --with-network)
      NETWORK_MODE="bridge"; shift ;;
    --allow-non-sandbox)
      ALLOW_NON_SANDBOX=true; shift ;;
    --help|-h)
      usage
      exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ -z "$WORKSPACE" ]]; then
  echo "--workspace is required" >&2
  usage
  exit 1
fi

if [[ ! -d "$WORKSPACE" ]]; then
  echo "Workspace path does not exist: $WORKSPACE" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker CLI not found. Install Docker or adjust the script to use another runtime." >&2
  exit 1
fi

ABS_WORKSPACE="$(cd "$WORKSPACE" && pwd)"

if [[ "$ALLOW_NON_SANDBOX" != true && ! -f "${ABS_WORKSPACE}/.platform-sandbox" ]]; then
  cat <<'WARN' >&2
[sandbox] Refusing to mount a directory without a .platform-sandbox marker.
[sandbox] Create the workspace via scripts/agent/create-project-workspace.sh or pass --allow-non-sandbox to override.
WARN
  exit 1
fi

DOCKER_ARGS=(
  run --rm -it
  --read-only
  --pids-limit 512
  --memory "$MEMORY_LIMIT"
  --cpus "$CPU_LIMIT"
  --security-opt no-new-privileges
  --cap-drop ALL
  --tmpfs /tmp:exec,mode=1777,size=256M
  --tmpfs /run:mode=0755,size=16M
  --mount "type=bind,source=${ABS_WORKSPACE},target=/workspace,readonly=false"
  --workdir /workspace
)

if [[ -n "$CONTAINER_NAME" ]]; then
  DOCKER_ARGS+=(--name "$CONTAINER_NAME")
fi

if [[ "$NETWORK_MODE" != "bridge" ]]; then
  DOCKER_ARGS+=(--network "$NETWORK_MODE")
else
  DOCKER_ARGS+=(--network bridge)
fi

DOCKER_ARGS+=("$IMAGE" "/bin/bash")

echo "[sandbox] Starting container using image $IMAGE"
echo "[sandbox] Workspace mounted at /workspace"

exec docker "${DOCKER_ARGS[@]}"
