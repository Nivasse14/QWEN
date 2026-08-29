#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd -P)"
health_interval="${STACK_ENTRYPOINT_HEALTH_INTERVAL:-30}"
exit_after_failures="${STACK_ENTRYPOINT_EXIT_AFTER_FAILURES:-0}"
consecutive_failures=0

[[ "${health_interval}" =~ ^[1-9][0-9]*$ ]] || {
  printf '[entrypoint] intervalle de santé invalide\n' >&2
  exit 2
}
[[ "${exit_after_failures}" =~ ^[0-9]+$ ]] || {
  printf "[entrypoint] seuil d'échec invalide\n" >&2
  exit 2
}

shutdown_stack() {
  local exit_code=$?
  trap - EXIT
  printf '[entrypoint] arrêt de la pile\n' >&2
  "${STACK_ROOT}/stop-stack.sh" || true
  exit "${exit_code}"
}
trap shutdown_stack EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

"${STACK_ROOT}/start-stack.sh"
printf '[entrypoint] pile démarrée; surveillance toutes les %ss\n' "${health_interval}" >&2

while true; do
  sleep "${health_interval}"
  if "${STACK_ROOT}/status-stack.sh" --quiet; then
    consecutive_failures=0
  else
    consecutive_failures=$((consecutive_failures + 1))
    printf '[entrypoint] contrôle de santé en échec (%s)\n' "${consecutive_failures}" >&2
    if (( exit_after_failures > 0 && consecutive_failures >= exit_after_failures )); then
      printf '[entrypoint] seuil atteint; sortie pour laisser RunPod redémarrer le conteneur\n' >&2
      exit 1
    fi
  fi
done
