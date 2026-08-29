#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TAILSCALE_RUN_DIR="${TAILSCALE_PRIVATE_RUN_DIR:-/run/ai-phone-stack/tailscale}"
TAILSCALE_PID_FILE="${TAILSCALE_PID_FILE:-${TAILSCALE_RUN_DIR}/tailscaled.pid}"
TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-${TAILSCALE_RUN_DIR}/tailscaled.sock}"

if pid_is_running "${TAILSCALE_PID_FILE}"; then
  process_id="$(tr -dc '0-9' < "${TAILSCALE_PID_FILE}")"
  log "Stopping tailscaled process ${process_id}"
  kill "${process_id}"
  for attempt in $(seq 1 15); do
    kill -0 "${process_id}" 2>/dev/null || break
    sleep 1
  done
  kill -0 "${process_id}" 2>/dev/null && warn "tailscaled is still running"
else
  log "tailscaled is not running"
fi

rm -f -- "${TAILSCALE_PID_FILE}" "${TAILSCALE_SOCKET}"
log "The Tailscale identity remains on the private container disk; it is recreated after Pod redeploy"
