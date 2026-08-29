#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if ! service_pid="$(comfyui_pid)"; then
  if [[ -e "$COMFYUI_PID_FILE" ]]; then
    log "PID périmé ou étranger ignoré; suppression du pidfile"
    rm -f "$COMFYUI_PID_FILE"
  else
    log "service absent; rien à arrêter"
  fi
  exit 0
fi

log "arrêt gracieux de ComfyUI (PID ${service_pid})"
kill -TERM "$service_pid"
deadline=$((SECONDS + COMFYUI_STOP_TIMEOUT))
while pid_is_alive "$service_pid" && (( SECONDS < deadline )); do
  sleep 1
done
if pid_is_alive "$service_pid"; then
  log "délai dépassé; arrêt forcé du PID géré ${service_pid}"
  kill -KILL "$service_pid"
fi
rm -f "$COMFYUI_PID_FILE"
log "ComfyUI arrêté"
