#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd -P)"
# shellcheck source=stack-common.sh
source "${SCRIPT_DIR}/stack-common.sh"

quiet=0
case "${1:-}" in
  "") ;;
  --quiet) quiet=1 ;;
  *) printf 'Usage: %s [--quiet]\n' "$0" >&2; exit 2 ;;
esac

export AI_PHONE_STACK_ROOT="${STACK_ROOT}"
export AI_PHONE_SECRET_DIR
export SEARXNG_PORT CODE_SERVER_PORT
export TAILSCALE_PRIVATE_RUN_DIR TAILSCALE_SOCKET TAILSCALE_PID_FILE

failures=0
report() {
  local label="$1" state="$2" detail="${3:-}"
  (( quiet == 1 )) || printf '%-20s %-12s %s\n' "${label}" "${state}" "${detail}"
}

probe_command() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    report "${label}" "ok"
  else
    report "${label}" "indisponible"
    failures=$((failures + 1))
  fi
}

probe_managed_http() {
  local pid_file="$1" marker="$2" url="$3"
  stack_managed_pid "${pid_file}" "${marker}" >/dev/null && stack_http_ok "${url}" 8
}

tailscale_is_running() {
  stack_managed_pid "${TAILSCALE_PID_FILE}" tailscaled >/dev/null || return 1
  [[ -x "${tailscale_cli}" && -S "${TAILSCALE_SOCKET}" ]] || return 1
  "${tailscale_cli}" --socket="${TAILSCALE_SOCKET}" status --json 2>/dev/null | \
    python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("BackendState") == "Running" else 1)'
}

(( quiet == 1 )) || printf '%-20s %-12s %s\n' SERVICE ETAT DETAIL
probe_command "SearXNG :${SEARXNG_PORT}" probe_managed_http \
  "${SEARXNG_STACK_PID_FILE}" granian "${SEARXNG_HEALTH_URL}"
probe_command "FLUX API :8003" "${STACK_ROOT}/comfyui/health-orchestrator.sh"
probe_command "Tools API :8002" "${STACK_ROOT}/tools-api/health.sh"
probe_command "Open WebUI :3000" "${STACK_ROOT}/openwebui/health.sh"
probe_command "code-server :8443" probe_managed_http \
  "${CODE_SERVER_STACK_PID_FILE}" code-server "${CODE_SERVER_HEALTH_URL}"

llm_ok=0
comfyui_ok=0
"${STACK_ROOT}/llm/health.sh" >/dev/null 2>&1 && llm_ok=1
"${STACK_ROOT}/comfyui/health.sh" >/dev/null 2>&1 && comfyui_ok=1
if (( llm_ok == 1 && comfyui_ok == 0 )); then
  report "GPU" "llm" "chat prêt sur :8000"
elif (( llm_ok == 0 && comfyui_ok == 1 )); then
  report "GPU" "image" "génération en cours sur :8188"
elif (( llm_ok == 1 && comfyui_ok == 1 )); then
  report "GPU" "conflit" "LLM et ComfyUI actifs ensemble"
  failures=$((failures + 1))
else
  report "GPU" "indisponible" "ni LLM ni ComfyUI"
  failures=$((failures + 1))
fi

tailscale_cli="${STACK_ROOT}/.runtime/tailscale/bin/tailscale"
tailscale_ip=""
if tailscale_is_running; then
  tailscale_ip="$("${tailscale_cli}" --socket="${TAILSCALE_SOCKET}" ip -4 2>/dev/null | head -n 1 || true)"
  report "Tailscale" "ok" "${tailscale_ip}"
else
  report "Tailscale" "indisponible"
  failures=$((failures + 1))
fi

if (( quiet == 0 && ${#tailscale_ip} > 0 )); then
  printf '\nURLs téléphone (Tailscale)\n'
  printf '  Open WebUI : http://%s:3000\n' "${tailscale_ip}"
  printf '  code-server: http://%s:8443\n' "${tailscale_ip}"
  printf '  ComfyUI    : http://%s:8188 (actif seulement en mode image)\n' "${tailscale_ip}"
fi

(( failures == 0 ))
