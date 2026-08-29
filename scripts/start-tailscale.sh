#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TAILSCALE_INSTALL_DIR="${TAILSCALE_INSTALL_DIR:-${RUNTIME_DIR}/tailscale}"
TAILSCALE_BIN_DIR="${TAILSCALE_INSTALL_DIR}/bin"
TAILSCALE_CLI="${TAILSCALE_BIN_DIR}/tailscale"
TAILSCALED_BIN="${TAILSCALE_BIN_DIR}/tailscaled"
TAILSCALE_RUN_DIR="${TAILSCALE_PRIVATE_RUN_DIR:-/run/ai-phone-stack/tailscale}"
# A Tailscale state file contains node credentials. Never place it on the
# RunPod network volume, whose FUSE mount exposes files as 0666. The private
# container disk is deliberately used instead; a redeploy reauthenticates from
# the injected auth key.
TAILSCALE_STATE_DIR="${TAILSCALE_PRIVATE_STATE_DIR:-/var/lib/ai-phone-stack/tailscale}"
TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-${TAILSCALE_RUN_DIR}/tailscaled.sock}"
TAILSCALE_STATE_FILE="${TAILSCALE_STATE_FILE:-${TAILSCALE_STATE_DIR}/tailscaled.state}"
TAILSCALE_PID_FILE="${TAILSCALE_PID_FILE:-${TAILSCALE_RUN_DIR}/tailscaled.pid}"
TAILSCALE_LOG_FILE="${TAILSCALE_LOG_FILE:-${TAILSCALE_RUN_DIR}/tailscaled.log}"

[[ -x "${TAILSCALE_CLI}" && -x "${TAILSCALED_BIN}" ]] || die \
  "Tailscale is not installed; run scripts/setup-tailscale.sh first"
require_command python3
ensure_stack_dirs
umask 077
install -d -m 0700 "${TAILSCALE_RUN_DIR}" || die \
  "Cannot create private Tailscale runtime directory at ${TAILSCALE_RUN_DIR}"
install -d -m 0700 "${TAILSCALE_STATE_DIR}" || die \
  "Cannot create private Tailscale state at ${TAILSCALE_STATE_DIR}; set TAILSCALE_PRIVATE_STATE_DIR to a non-FUSE private path"
state_dir_mode="$(stat -c '%a' "${TAILSCALE_STATE_DIR}" 2>/dev/null || true)"
[[ "${state_dir_mode}" =~ ^[0-7]+$ ]] || die "Cannot verify Tailscale state permissions"
(( ((8#${state_dir_mode}) & 8#077) == 0 )) || die \
  "Tailscale state directory is not private (mode ${state_dir_mode}); do not use the RunPod network volume"

tailscale_cli() {
  "${TAILSCALE_CLI}" --socket="${TAILSCALE_SOCKET}" "$@"
}

if ! pid_is_running "${TAILSCALE_PID_FILE}"; then
  rm -f -- "${TAILSCALE_SOCKET}" "${TAILSCALE_PID_FILE}"
  log "Starting tailscaled with its userspace network stack"
  nohup "${TAILSCALED_BIN}" \
    --tun=userspace-networking \
    --state="${TAILSCALE_STATE_FILE}" \
    --socket="${TAILSCALE_SOCKET}" \
    --socks5-server="127.0.0.1:${TAILSCALE_SOCKS5_PORT:-1055}" \
    --outbound-http-proxy-listen="127.0.0.1:${TAILSCALE_HTTP_PROXY_PORT:-1056}" \
    >"${TAILSCALE_LOG_FILE}" 2>&1 &
  printf '%s\n' "$!" > "${TAILSCALE_PID_FILE}"
fi

for attempt in $(seq 1 30); do
  [[ -S "${TAILSCALE_SOCKET}" ]] && break
  sleep 1
done
[[ -S "${TAILSCALE_SOCKET}" ]] || die \
  "tailscaled did not create its socket; inspect ${TAILSCALE_LOG_FILE}"

backend_state="$(tailscale_cli status --json 2>/dev/null | python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("BackendState", ""))' 2>/dev/null || true)"
if [[ "${backend_state}" != "Running" ]]; then
  if [[ -z "${TAILSCALE_AUTH_KEY:-}" && -n "${TAILSCALE_AUTH_KEY_FILE:-}" ]]; then
    TAILSCALE_AUTH_KEY="$(read_secret_file "${TAILSCALE_AUTH_KEY_FILE}")"
  fi
  [[ -n "${TAILSCALE_AUTH_KEY:-}" ]] || die \
    "This node is not connected; set TAILSCALE_AUTH_KEY or TAILSCALE_AUTH_KEY_FILE"
  log "Authenticating the Tailscale node (the key is not printed)"
  tailscale_cli up \
    --auth-key="${TAILSCALE_AUTH_KEY}" \
    --hostname="${TAILSCALE_HOSTNAME:-runpod-ai-phone}" \
    --accept-dns=false
fi

TAILSCALE_SOCKET="${TAILSCALE_SOCKET}" "${SCRIPT_DIR}/configure-tailscale-serve.sh"
log "Tailscale IPv4 address: $(tailscale_cli ip -4)"
warn "RunPod Pods do not expose UDP; peer traffic can therefore use a DERP relay"
