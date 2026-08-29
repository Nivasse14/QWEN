#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if pid_is_running; then
  log "déjà actif (PID $(cat "$PID_FILE"))"
  exec "${SCRIPT_DIR}/health.sh"
fi
umask 077
install -d -m 0700 "$PRIVATE_RUN_DIR" "$PRIVATE_WORK_DIR"
mkdir -p -- "$(dirname -- "$LOG_FILE")"
rm -f -- "$PID_FILE"

nohup env -i \
  HOME=/root \
  PATH=/usr/local/bin:/usr/bin:/bin \
  LANG=C.UTF-8 \
  AI_PHONE_STACK_ROOT="$STACK_ROOT" \
  AI_PHONE_SECRET_DIR="$SECRET_DIR" \
  OPENWEBUI_VENV_DIR="$OPENWEBUI_VENV_DIR" \
  OPENWEBUI_DATA_DIR="$OPENWEBUI_DATA_DIR" \
  OPENWEBUI_PRIVATE_DIR="$PRIVATE_WORK_DIR" \
  "${SCRIPT_DIR}/run.sh" >"$LOG_FILE" 2>&1 &
printf '%s\n' "$!" > "$PID_FILE"

for _attempt in $(seq 1 180); do
  if curl -fsS "http://127.0.0.1:${OPENWEBUI_PORT:-3000}/health" >/dev/null; then
    exec "${SCRIPT_DIR}/health.sh"
  fi
  pid_is_running || break
  sleep 1
done
tail -n 100 "$LOG_FILE" >&2 || true
die "échec du démarrage"
