#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
STACK_ROOT="${AI_PHONE_STACK_ROOT:-$(cd -- "${SCRIPT_DIR}/.." && pwd -P)}"
OPENWEBUI_VENV_DIR="${OPENWEBUI_VENV_DIR:-/workspace/open-webui-venv}"
OPENWEBUI_DATA_DIR="${OPENWEBUI_DATA_DIR:-/workspace/open-webui-data}"
PRIVATE_RUN_DIR="${OPENWEBUI_RUN_DIR:-/run/ai-phone-stack/openwebui}"
PRIVATE_WORK_DIR="${OPENWEBUI_PRIVATE_DIR:-/var/lib/ai-phone-stack/openwebui}"
PID_FILE="${OPENWEBUI_PID_FILE:-${PRIVATE_RUN_DIR}/openwebui.pid}"
LOG_FILE="${OPENWEBUI_LOG_FILE:-/workspace/logs/openwebui.log}"
SECRET_DIR="${AI_PHONE_SECRET_DIR:-/run/secrets/ai-phone-stack}"

log() {
  printf '[openwebui] %s\n' "$*"
}

die() {
  printf '[openwebui] ERROR: %s\n' "$*" >&2
  exit 1
}

read_private_secret() {
  local path="$1"
  [[ -f "$path" && -r "$path" ]] || die "secret absent: $path"
  local mode
  mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  [[ "$mode" =~ ^[0-7]+$ ]] || die "permissions invérifiables: $path"
  (( ((8#$mode) & 8#077) == 0 )) || die "secret trop ouvert ($mode): $path"
  tr -d '\r\n' < "$path"
}

pid_is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local process_id
  process_id="$(tr -dc '0-9' < "$PID_FILE")"
  [[ -n "$process_id" ]] && kill -0 "$process_id" 2>/dev/null
}
