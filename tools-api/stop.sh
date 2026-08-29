#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if ! pid_is_running; then
  rm -f -- "$PID_FILE"
  log "déjà arrêté"
  exit 0
fi
process_id="$(tr -dc '0-9' < "$PID_FILE")"
kill -TERM "$process_id"
for _attempt in $(seq 1 20); do
  kill -0 "$process_id" 2>/dev/null || break
  sleep 1
done
if kill -0 "$process_id" 2>/dev/null; then
  kill -KILL "$process_id"
fi
rm -f -- "$PID_FILE"
log "arrêté"
