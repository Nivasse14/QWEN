#!/usr/bin/env bash

set -Eeuo pipefail

LLM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ -f "${LLM_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${LLM_DIR}/.env"
  set +a
fi

LLAMA_CPP_SOURCE="${LLAMA_CPP_SOURCE:-/workspace/llama.cpp}"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-${LLAMA_CPP_SOURCE}/build/bin/llama-server}"
LLAMA_BIND_ADDRESS="${LLAMA_BIND_ADDRESS:-127.0.0.1}"
LLAMA_PORT="${LLAMA_PORT:-8000}"
LLAMA_ALIAS="${LLAMA_ALIAS:-qwen3.8-uncensored}"
LLAMA_CONTEXT_SIZE="${LLAMA_CONTEXT_SIZE:-16384}"
LLAMA_GPU_LAYERS="${LLAMA_GPU_LAYERS:-999}"
LLAMA_PARALLEL="${LLAMA_PARALLEL:-1}"
LLAMA_START_TIMEOUT="${LLAMA_START_TIMEOUT:-300}"
LLAMA_STOP_TIMEOUT="${LLAMA_STOP_TIMEOUT:-45}"

LLAMA_MODEL_REPO="${LLAMA_MODEL_REPO:-JonathanColetti/Qwen3.8-27B-Uncensored-GGUF}"
LLAMA_MODEL_FILENAME="${LLAMA_MODEL_FILENAME:-Qwen3.8-27B-Uncensored-Q4_K_M.gguf}"
LLAMA_MODEL_DIR="${LLAMA_MODEL_DIR:-/workspace/models/llm}"
LLAMA_MODEL_FILE="${LLAMA_MODEL_FILE:-${LLAMA_MODEL_DIR}/${LLAMA_MODEL_FILENAME}}"
LLAMA_MODEL_SHA256="${LLAMA_MODEL_SHA256:-}"

AI_STACK_RUNTIME_DIR="${AI_STACK_RUNTIME_DIR:-/workspace/run/ai-phone-stack}"
LLAMA_PID_FILE="${LLAMA_PID_FILE:-${AI_STACK_RUNTIME_DIR}/llama-server.pid}"
LLAMA_LOG_FILE="${LLAMA_LOG_FILE:-${AI_STACK_RUNTIME_DIR}/llama-server.log}"
COMFYUI_PID_FILE="${COMFYUI_PID_FILE:-${AI_STACK_RUNTIME_DIR}/comfyui.pid}"
LLAMA_API_KEY_FILE="${LLAMA_API_KEY_FILE:-/run/secrets/ai-phone-stack/llama_api_key}"
LLAMA_REQUIRE_API_KEY="${LLAMA_REQUIRE_API_KEY:-0}"
LLAMA_BASE_URL="${LLAMA_BASE_URL:-http://127.0.0.1:${LLAMA_PORT}}"

log() {
  printf '[llm] %s\n' "$*" >&2
}

die() {
  log "ERREUR: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "commande requise introuvable: $1"
}

require_absolute_path() {
  [[ "$1" == /* ]] || die "un chemin absolu est requis: $1"
}

pid_from_file() {
  local pid_file="$1"
  local pid=""
  [[ -r "$pid_file" ]] || return 1
  read -r pid <"$pid_file" || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$pid"
}

pid_is_alive() {
  local pid="$1"
  local proc_stat rest state
  kill -0 "$pid" 2>/dev/null || return 1
  if [[ -r "/proc/${pid}/stat" ]]; then
    proc_stat="$(<"/proc/${pid}/stat")"
    rest="${proc_stat##*) }"
    state="${rest%% *}"
    [[ "$state" != "Z" && "$state" != "X" ]] || return 1
  fi
  return 0
}

pid_matches_marker() {
  local pid="$1"
  local marker="$2"
  if [[ -r "/proc/${pid}/cmdline" ]]; then
    tr '\0' ' ' <"/proc/${pid}/cmdline" | grep -F -- "$marker" >/dev/null
  else
    ps -p "$pid" -o command= 2>/dev/null | grep -F -- "$marker" >/dev/null
  fi
}

managed_pid() {
  local pid_file="$1"
  local marker="$2"
  local pid
  pid="$(pid_from_file "$pid_file")" || return 1
  pid_is_alive "$pid" || return 1
  pid_matches_marker "$pid" "$marker" || return 1
  printf '%s\n' "$pid"
}

pidfile_process_alive() {
  local pid
  pid="$(pid_from_file "$1")" || return 1
  pid_is_alive "$pid"
}

llama_pid() {
  managed_pid "$LLAMA_PID_FILE" "$LLAMA_SERVER_BIN" 2>/dev/null || discover_llama_pid
}

discover_llama_pid() {
  local cmdline_file pid cmdline
  local -a matches=()
  [[ -d /proc ]] || return 1
  for cmdline_file in /proc/[1-9]*/cmdline; do
    [[ -r "$cmdline_file" ]] || continue
    pid="${cmdline_file#/proc/}"
    pid="${pid%/cmdline}"
    cmdline="$(tr '\0' ' ' <"$cmdline_file")"
    [[ "$cmdline" == *"$LLAMA_SERVER_BIN"* ]] || continue
    if [[ "$cmdline" == *"--port ${LLAMA_PORT}"* \
      || "$cmdline" == *"--port=${LLAMA_PORT}"* \
      || "$cmdline" == *"-p ${LLAMA_PORT}"* ]]; then
      matches+=("$pid")
    fi
  done
  (( ${#matches[@]} == 1 )) || return 1
  printf '%s\n' "${matches[0]}"
}

first_api_key() {
  [[ -n "$LLAMA_API_KEY_FILE" && -r "$LLAMA_API_KEY_FILE" ]] || return 1
  awk 'NF && $1 !~ /^#/ { print $1; exit }' "$LLAMA_API_KEY_FILE"
}

wait_for_http() {
  local url="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if curl --fail --silent --show-error --max-time 5 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}
