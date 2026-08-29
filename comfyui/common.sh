#!/usr/bin/env bash

set -Eeuo pipefail

COMFYUI_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ -f "${COMFYUI_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${COMFYUI_DIR}/.env"
  set +a
fi

COMFYUI_SOURCE_DIR="${COMFYUI_SOURCE_DIR:-/workspace/ComfyUI}"
COMFYUI_REPO="${COMFYUI_REPO:-https://github.com/Comfy-Org/ComfyUI.git}"
COMFYUI_REF="${COMFYUI_REF:-master}"
COMFYUI_VENV_DIR="${COMFYUI_VENV_DIR:-/workspace/venvs/comfyui}"
COMFYUI_PYTHON="${COMFYUI_PYTHON:-${COMFYUI_VENV_DIR}/bin/python}"
COMFYUI_MAIN="${COMFYUI_MAIN:-${COMFYUI_SOURCE_DIR}/main.py}"
COMFYUI_BIND_ADDRESS="${COMFYUI_BIND_ADDRESS:-127.0.0.1}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
COMFYUI_URL="${COMFYUI_URL:-http://127.0.0.1:${COMFYUI_PORT}}"
COMFYUI_START_TIMEOUT="${COMFYUI_START_TIMEOUT:-600}"
COMFYUI_STOP_TIMEOUT="${COMFYUI_STOP_TIMEOUT:-45}"
COMFYUI_VRAM_MODE="${COMFYUI_VRAM_MODE:-lowvram}"

COMFYUI_MODELS_DIR="${COMFYUI_MODELS_DIR:-${COMFYUI_SOURCE_DIR}/models}"
COMFYUI_CUSTOM_NODES_DIR="${COMFYUI_CUSTOM_NODES_DIR:-${COMFYUI_SOURCE_DIR}/custom_nodes}"
COMFYUI_INPUT_DIR="${COMFYUI_INPUT_DIR:-${COMFYUI_SOURCE_DIR}/input}"
COMFYUI_OUTPUT_DIR="${COMFYUI_OUTPUT_DIR:-${COMFYUI_SOURCE_DIR}/output}"
COMFYUI_USER_DIR="${COMFYUI_USER_DIR:-${COMFYUI_SOURCE_DIR}/user}"

AI_STACK_RUNTIME_DIR="${AI_STACK_RUNTIME_DIR:-/workspace/run/ai-phone-stack}"
COMFYUI_PID_FILE="${COMFYUI_PID_FILE:-${AI_STACK_RUNTIME_DIR}/comfyui.pid}"
COMFYUI_LOG_FILE="${COMFYUI_LOG_FILE:-${AI_STACK_RUNTIME_DIR}/comfyui.log}"
LLAMA_PID_FILE="${LLAMA_PID_FILE:-${AI_STACK_RUNTIME_DIR}/llama-server.pid}"
FLUX_ORCHESTRATOR_BIND="${FLUX_ORCHESTRATOR_BIND:-127.0.0.1}"
FLUX_ORCHESTRATOR_PORT="${FLUX_ORCHESTRATOR_PORT:-8003}"
FLUX_ORCHESTRATOR_BASE_URL="${FLUX_ORCHESTRATOR_BASE_URL:-http://127.0.0.1:${FLUX_ORCHESTRATOR_PORT}}"
FLUX_ORCHESTRATOR_URL="${FLUX_ORCHESTRATOR_URL:-${FLUX_ORCHESTRATOR_BASE_URL}/v1/images/generations}"
FLUX_ORCHESTRATOR_PYTHON="${FLUX_ORCHESTRATOR_PYTHON:-python3}"
FLUX_ORCHESTRATOR_PID_FILE="${FLUX_ORCHESTRATOR_PID_FILE:-${AI_STACK_RUNTIME_DIR}/flux-orchestrator.pid}"
FLUX_ORCHESTRATOR_LOG_FILE="${FLUX_ORCHESTRATOR_LOG_FILE:-${AI_STACK_RUNTIME_DIR}/flux-orchestrator.log}"
FLUX_ORCHESTRATOR_API_KEY_FILE="${FLUX_ORCHESTRATOR_API_KEY_FILE:-/run/secrets/ai-phone-stack/flux_orchestrator_token}"

COMFYUI_GGUF_REPO="${COMFYUI_GGUF_REPO:-https://github.com/city96/ComfyUI-GGUF.git}"
COMFYUI_GGUF_REF="${COMFYUI_GGUF_REF:-main}"
COMFYUI_GGUF_DIR="${COMFYUI_GGUF_DIR:-${COMFYUI_CUSTOM_NODES_DIR}/ComfyUI-GGUF}"

FLUX_UNET_REPO="${FLUX_UNET_REPO:-city96/FLUX.1-dev-gguf}"
FLUX_UNET_FILENAME="${FLUX_UNET_FILENAME:-flux1-dev-Q5_K_S.gguf}"
FLUX_UNET_PATH="${FLUX_UNET_PATH:-${COMFYUI_MODELS_DIR}/unet/${FLUX_UNET_FILENAME}}"
FLUX_UNET_SHA256="${FLUX_UNET_SHA256:-}"
FLUX_T5_REPO="${FLUX_T5_REPO:-city96/t5-v1_1-xxl-encoder-gguf}"
FLUX_T5_FILENAME="${FLUX_T5_FILENAME:-t5-v1_1-xxl-encoder-Q4_K_M.gguf}"
FLUX_T5_PATH="${FLUX_T5_PATH:-${COMFYUI_MODELS_DIR}/text_encoders/${FLUX_T5_FILENAME}}"
FLUX_T5_SHA256="${FLUX_T5_SHA256:-}"
FLUX_CLIP_REPO="${FLUX_CLIP_REPO:-comfyanonymous/flux_text_encoders}"
FLUX_CLIP_FILENAME="${FLUX_CLIP_FILENAME:-clip_l.safetensors}"
FLUX_CLIP_PATH="${FLUX_CLIP_PATH:-${COMFYUI_MODELS_DIR}/text_encoders/${FLUX_CLIP_FILENAME}}"
FLUX_CLIP_SHA256="${FLUX_CLIP_SHA256:-}"
FLUX_VAE_REPO="${FLUX_VAE_REPO:-black-forest-labs/FLUX.1-dev}"
FLUX_VAE_FILENAME="${FLUX_VAE_FILENAME:-ae.safetensors}"
FLUX_VAE_PATH="${FLUX_VAE_PATH:-${COMFYUI_MODELS_DIR}/vae/${FLUX_VAE_FILENAME}}"
FLUX_VAE_SHA256="${FLUX_VAE_SHA256:-}"

log() {
  printf '[comfyui] %s\n' "$*" >&2
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
  local pid=""
  [[ -r "$1" ]] || return 1
  read -r pid <"$1" || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$pid"
}

pid_is_alive() {
  local pid="$1" proc_stat rest state
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
  local pid="$1" marker="$2"
  if [[ -r "/proc/${pid}/cmdline" ]]; then
    tr '\0' ' ' <"/proc/${pid}/cmdline" | grep -F -- "$marker" >/dev/null
  else
    ps -p "$pid" -o command= 2>/dev/null | grep -F -- "$marker" >/dev/null
  fi
}

managed_pid() {
  local pid
  pid="$(pid_from_file "$1")" || return 1
  pid_is_alive "$pid" || return 1
  pid_matches_marker "$pid" "$2" || return 1
  printf '%s\n' "$pid"
}

pidfile_process_alive() {
  local pid
  pid="$(pid_from_file "$1")" || return 1
  pid_is_alive "$pid"
}

comfyui_pid() {
  managed_pid "$COMFYUI_PID_FILE" "$COMFYUI_MAIN"
}

orchestrator_pid() {
  managed_pid "$FLUX_ORCHESTRATOR_PID_FILE" "${COMFYUI_DIR}/orchestrator.py"
}

wait_for_http() {
  local deadline=$((SECONDS + $2))
  while (( SECONDS < deadline )); do
    if curl --fail --silent --show-error --max-time 5 "$1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}
