#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
COMFYUI_DIR="$(cd -- "${SCRIPT_DIR}/../comfyui" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

LOCK_DIR="${GPU_MUTEX_DIR:-${AI_STACK_RUNTIME_DIR}/gpu-switch.lock}"
STATE_FILE="${GPU_MODE_STATE_FILE:-${AI_STACK_RUNTIME_DIR}/gpu-mode}"
GPU_MUTEX_TIMEOUT="${GPU_MUTEX_TIMEOUT:-60}"
lock_held=0

usage() {
  printf 'Usage: %s {llm|comfyui|off|status}\n' "$0"
}

cleanup_lock() {
  if (( lock_held )); then
    rm -f "${LOCK_DIR}/owner"
    rmdir "$LOCK_DIR" 2>/dev/null || true
    lock_held=0
  fi
}

acquire_lock() {
  local deadline=$((SECONDS + GPU_MUTEX_TIMEOUT))
  local owner_pid owner_host current_host
  local owner_missing_since=0
  install -d -m 0750 "$AI_STACK_RUNTIME_DIR"
  current_host="$(hostname)"

  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    owner_pid=""
    owner_host=""
    if [[ -r "${LOCK_DIR}/owner" ]]; then
      read -r owner_pid owner_host <"${LOCK_DIR}/owner" || true
    fi
    if [[ ! "$owner_pid" =~ ^[1-9][0-9]*$ || -z "$owner_host" ]]; then
      if (( owner_missing_since == 0 )); then
        owner_missing_since=$SECONDS
      elif (( SECONDS - owner_missing_since >= 5 )); then
        rm -f "${LOCK_DIR}/owner"
        rmdir "$LOCK_DIR" 2>/dev/null || true
        owner_missing_since=0
        continue
      fi
    else
      owner_missing_since=0
    fi
    if [[ -n "$owner_host" && "$owner_host" != "$current_host" ]]; then
      rm -f "${LOCK_DIR}/owner"
      rmdir "$LOCK_DIR" 2>/dev/null || true
      continue
    fi
    if [[ "$owner_host" == "$current_host" && "$owner_pid" =~ ^[1-9][0-9]*$ ]] \
      && ! pid_is_alive "$owner_pid"; then
      rm -f "${LOCK_DIR}/owner"
      rmdir "$LOCK_DIR" 2>/dev/null || true
      continue
    fi
    (( SECONDS < deadline )) || die "verrou GPU occupé depuis plus de ${GPU_MUTEX_TIMEOUT}s"
    sleep 1
  done
  lock_held=1
  printf '%s %s\n' "$$" "$current_host" >"${LOCK_DIR}/owner"
  trap cleanup_lock EXIT INT TERM
}

write_state() {
  local temporary="${STATE_FILE}.$$"
  printf '%s\n' "$1" >"$temporary"
  mv -f "$temporary" "$STATE_FILE"
}

show_status() {
  local llm_state="stopped" comfy_state="stopped"
  llama_pid >/dev/null 2>&1 && llm_state="running"
  pidfile_process_alive "$COMFYUI_PID_FILE" && comfy_state="running"
  printf '{"llm":"%s","comfyui":"%s"}\n' "$llm_state" "$comfy_state"
}

mode="${1:-}"
case "$mode" in
  status) show_status; exit 0 ;;
  llm|comfyui|off) ;;
  *) usage >&2; exit 2 ;;
esac

acquire_lock
case "$mode" in
  llm)
    "${COMFYUI_DIR}/stop.sh"
    "${SCRIPT_DIR}/start.sh"
    write_state llm
    ;;
  comfyui)
    "${SCRIPT_DIR}/stop.sh"
    "${COMFYUI_DIR}/start.sh"
    write_state comfyui
    ;;
  off)
    "${SCRIPT_DIR}/stop.sh"
    "${COMFYUI_DIR}/stop.sh"
    write_state off
    ;;
esac
show_status
