#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if ! service_pid="$(orchestrator_pid)"; then
  [[ ! -e "$FLUX_ORCHESTRATOR_PID_FILE" ]] || rm -f "$FLUX_ORCHESTRATOR_PID_FILE"
  log "orchestrateur absent"
  exit 0
fi
kill -TERM "$service_pid"
deadline=$((SECONDS + 20))
while pid_is_alive "$service_pid" && (( SECONDS < deadline )); do sleep 1; done
if pid_is_alive "$service_pid"; then kill -KILL "$service_pid"; fi
rm -f "$FLUX_ORCHESTRATOR_PID_FILE"
log "orchestrateur arrêté"
