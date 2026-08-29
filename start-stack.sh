#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd -P)"
# shellcheck source=stack-common.sh
source "${SCRIPT_DIR}/stack-common.sh"

export AI_PHONE_STACK_ROOT="${STACK_ROOT}"
export AI_PHONE_SECRET_DIR
export SEARXNG_PORT
export CODE_SERVER_PORT
export TAILSCALE_PRIVATE_RUN_DIR TAILSCALE_SOCKET TAILSCALE_PID_FILE
export GITHUB_ALLOWED_REPOS="${GITHUB_ALLOWED_REPOS:-Nivasse14/QWEN}"
export CODE_WORKSPACE="${CODE_WORKSPACE:-/workspace/repos/Nivasse14/QWEN}"

rollback_on_error() {
  local exit_code=$?
  trap - ERR
  stack_warn "démarrage incomplet (code ${exit_code})"
  if [[ "${STACK_ROLLBACK_ON_ERROR:-1}" == "1" ]]; then
    stack_warn "retour à l'état arrêté"
    STACK_LOCK_HELD=1 "${STACK_ROOT}/stop-stack.sh" || true
  fi
  exit "${exit_code}"
}

stack_acquire_lock
trap stack_release_lock EXIT
trap rollback_on_error ERR

[[ "$(id -u)" -eq 0 ]] || stack_die "le démarrage complet doit être exécuté par root"
stack_require_command curl
stack_prepare_private_dirs

stack_log "préparation des secrets privés d'exécution"
"${STACK_ROOT}/scripts/bootstrap-secrets.sh"
stack_require_private_secret github_token
stack_require_private_secret tailscale_auth_key
stack_require_private_secret searxng_secret
stack_require_private_secret code_server_password
stack_require_private_secret tools_api_token
stack_require_private_secret flux_orchestrator_token
stack_require_private_secret webui_secret_key

stack_start_managed_exec \
  "SearXNG" "${SEARXNG_STACK_PID_FILE}" "${SEARXNG_STACK_LOG_FILE}" \
  "granian" "${SEARXNG_HEALTH_URL}" 90 \
  env AI_PHONE_STACK_ROOT="${STACK_ROOT}" \
    AI_PHONE_SECRET_DIR="${AI_PHONE_SECRET_DIR}" \
    SEARXNG_PORT="${SEARXNG_PORT}" \
    SEARXNG_SECRET_FILE="${AI_PHONE_SECRET_DIR}/searxng_secret" \
    "${STACK_ROOT}/scripts/start-searxng.sh"

stack_log "activation du mode GPU LLM"
"${STACK_ROOT}/llm/gpu-mode.sh" llm

"${STACK_ROOT}/comfyui/start-orchestrator.sh"
"${STACK_ROOT}/tools-api/start.sh"
"${STACK_ROOT}/openwebui/start.sh"

stack_start_managed_exec \
  "code-server" "${CODE_SERVER_STACK_PID_FILE}" "${CODE_SERVER_STACK_LOG_FILE}" \
  "code-server" "${CODE_SERVER_HEALTH_URL}" 90 \
  env AI_PHONE_STACK_ROOT="${STACK_ROOT}" \
    CODE_SERVER_PORT="${CODE_SERVER_PORT}" \
    CODE_WORKSPACE="${CODE_WORKSPACE}" \
    CODE_SERVER_PASSWORD_FILE="${AI_PHONE_SECRET_DIR}/code_server_password" \
    "${STACK_ROOT}/scripts/start-code-server.sh"

if tailscale_pid="$(stack_pid_from_file "${TAILSCALE_PID_FILE}" 2>/dev/null)" \
  && kill -0 "${tailscale_pid}" 2>/dev/null; then
  stack_pid_matches "${tailscale_pid}" tailscaled || stack_die \
    "Tailscale: le PID ${tailscale_pid} appartient à un autre processus"
fi
TAILSCALE_AUTH_KEY_FILE="${AI_PHONE_SECRET_DIR}/tailscale_auth_key" \
  TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-qwen-runpod}" \
  "${STACK_ROOT}/scripts/start-tailscale.sh"

"${STACK_ROOT}/status-stack.sh" --quiet
trap - ERR
stack_log "pile native prête"
"${STACK_ROOT}/status-stack.sh"
