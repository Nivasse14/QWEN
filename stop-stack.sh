#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd -P)"
# shellcheck source=stack-common.sh
source "${SCRIPT_DIR}/stack-common.sh"

export AI_PHONE_STACK_ROOT="${STACK_ROOT}"
export AI_PHONE_SECRET_DIR
export SEARXNG_PORT CODE_SERVER_PORT
export TAILSCALE_PRIVATE_RUN_DIR TAILSCALE_SOCKET TAILSCALE_PID_FILE

failures=0
run_stop() {
  local label="$1"
  shift
  if ! "$@"; then
    stack_warn "échec de l'arrêt: ${label}"
    failures=$((failures + 1))
  fi
}

stop_tailscale_managed() {
  local result=0
  stack_stop_managed_exec "Tailscale" "${TAILSCALE_PID_FILE}" tailscaled 20 || result=$?
  rm -f -- "${TAILSCALE_SOCKET}"
  return "${result}"
}

stack_acquire_lock
trap stack_release_lock EXIT

# Couper d'abord l'accès tailnet, puis les consommateurs, puis le GPU.
run_stop "Tailscale" stop_tailscale_managed
run_stop "code-server" stack_stop_managed_exec \
  "code-server" "${CODE_SERVER_STACK_PID_FILE}" "code-server" 30
run_stop "Open WebUI" "${STACK_ROOT}/openwebui/stop.sh"
run_stop "Tools API" "${STACK_ROOT}/tools-api/stop.sh"
run_stop "orchestrateur FLUX" "${STACK_ROOT}/comfyui/stop-orchestrator.sh"
run_stop "SearXNG" stack_stop_managed_exec \
  "SearXNG" "${SEARXNG_STACK_PID_FILE}" "granian" 30
run_stop "GPU" "${STACK_ROOT}/llm/gpu-mode.sh" off

if (( failures > 0 )); then
  stack_die "arrêt terminé avec ${failures} erreur(s)"
fi
stack_log "pile arrêtée"
