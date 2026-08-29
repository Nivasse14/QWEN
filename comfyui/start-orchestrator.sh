#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_command curl
require_command nohup
require_command "$FLUX_ORCHESTRATOR_PYTHON"
[[ "$FLUX_ORCHESTRATOR_BIND" == "127.0.0.1" ]] || die "l'orchestrateur doit rester sur 127.0.0.1"
if [[ -n "$FLUX_ORCHESTRATOR_API_KEY_FILE" ]]; then
  [[ "$FLUX_ORCHESTRATOR_API_KEY_FILE" == /run/* ]] || die "la clé orchestrateur doit rester sous /run"
fi

if service_pid="$(orchestrator_pid)"; then
  log "orchestrateur déjà actif (PID ${service_pid})"
  exec "${SCRIPT_DIR}/health-orchestrator.sh"
fi
[[ ! -e "$FLUX_ORCHESTRATOR_PID_FILE" ]] || rm -f "$FLUX_ORCHESTRATOR_PID_FILE"
if curl --fail --silent --max-time 3 "${FLUX_ORCHESTRATOR_BASE_URL}/health" >/dev/null 2>&1; then
  die "un orchestrateur non géré répond déjà sur ${FLUX_ORCHESTRATOR_BASE_URL}"
fi

install -d -m 0750 "$AI_STACK_RUNTIME_DIR"
touch "$FLUX_ORCHESTRATOR_LOG_FILE"
chmod 0640 "$FLUX_ORCHESTRATOR_LOG_FILE" 2>/dev/null || true
nohup "$FLUX_ORCHESTRATOR_PYTHON" "${SCRIPT_DIR}/orchestrator.py" \
  --host "$FLUX_ORCHESTRATOR_BIND" --port "$FLUX_ORCHESTRATOR_PORT" \
  >>"$FLUX_ORCHESTRATOR_LOG_FILE" 2>&1 </dev/null &
service_pid=$!
printf '%s\n' "$service_pid" >"${FLUX_ORCHESTRATOR_PID_FILE}.$$"
mv -f "${FLUX_ORCHESTRATOR_PID_FILE}.$$" "$FLUX_ORCHESTRATOR_PID_FILE"

if ! wait_for_http "${FLUX_ORCHESTRATOR_BASE_URL}/health" 30; then
  tail -n 100 "$FLUX_ORCHESTRATOR_LOG_FILE" >&2 || true
  "${SCRIPT_DIR}/stop-orchestrator.sh" || true
  die "orchestrateur images non sain"
fi
"${SCRIPT_DIR}/health-orchestrator.sh"
