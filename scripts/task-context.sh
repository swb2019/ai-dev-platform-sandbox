#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_FILE="$ROOT_DIR/config/task-context.json"
ACTION=""
KEY=""
VALUE=""
EDITOR="${VISUAL:-${EDITOR:-code}}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/task-context.sh [--show|--set key value|--clear key|--edit]

  --show            Print the current task context
  --set key value   Update a specific key (currentGoal, acceptanceCriteria, remainingTodos)
  --clear key       Clear the specified key
  --edit            Open the task context in an editor
USAGE
}

print_context() {
  if [[ ! -f "$TASK_FILE" ]]; then
    echo "{}"
  else
    cat "$TASK_FILE"
  fi
}

set_value() {
  local key="$1" value="$2"
  python3 - "$TASK_FILE" "$key" "$value" <<'PY'
import json, sys, datetime
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.load(open(path))
except FileNotFoundError:
    data = {}

if key in {"acceptanceCriteria", "remainingTodos"}:
    items = [item.strip() for item in value.split(";") if item.strip()]
    data[key] = items
else:
    data[key] = value

data["lastUpdated"] = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

clear_value() {
  local key="$1"
  python3 - "$TASK_FILE" "$key" <<'PY'
import json, sys, datetime
path, key = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except FileNotFoundError:
    data = {}

if key in data:
    if isinstance(data[key], list):
        data[key] = []
    else:
        data[key] = ""

data["lastUpdated"] = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show)
      ACTION="show"
      shift
      ;;
    --set)
      ACTION="set"
      KEY="$2"
      VALUE="$3"
      shift 3
      ;;
    --clear)
      ACTION="clear"
      KEY="$2"
      shift 2
      ;;
    --edit)
      ACTION="edit"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

case "$ACTION" in
  "show")
    print_context
    ;;
  "set")
    set_value "$KEY" "$VALUE"
    print_context
    ;;
  "clear")
    clear_value "$KEY"
    print_context
    ;;
  "edit")
    "$EDITOR" "$TASK_FILE"
    ;;
  *)
    usage
    exit 1
    ;;
esac
