#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TAILSCALE_INSTALL_DIR="${TAILSCALE_INSTALL_DIR:-${RUNTIME_DIR}/tailscale}"
TAILSCALE_CLI="${TAILSCALE_INSTALL_DIR}/bin/tailscale"
TAILSCALE_PRIVATE_RUN_DIR="${TAILSCALE_PRIVATE_RUN_DIR:-/run/ai-phone-stack/tailscale}"
TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-${TAILSCALE_PRIVATE_RUN_DIR}/tailscaled.sock}"
[[ -x "${TAILSCALE_CLI}" ]] || die "Run scripts/setup-tailscale.sh first"
[[ -S "${TAILSCALE_SOCKET}" ]] || die "Tailscale daemon socket not found: ${TAILSCALE_SOCKET}"

tailscale_cli() {
  "${TAILSCALE_CLI}" --socket="${TAILSCALE_SOCKET}" "$@"
}

serve_tcp() {
  local tailnet_port="$1"
  local local_port="$2"
  local label="$3"
  log "Publishing ${label}: tailnet TCP ${tailnet_port} -> 127.0.0.1:${local_port}"
  tailscale_cli serve --bg --tcp="${tailnet_port}" \
    "tcp://127.0.0.1:${local_port}"
}

serve_tcp "${OPEN_WEBUI_TAILNET_PORT:-3000}" "${OPEN_WEBUI_LOCAL_PORT:-3000}" "Open WebUI"
serve_tcp "${CODE_SERVER_TAILNET_PORT:-8443}" "${CODE_SERVER_LOCAL_PORT:-8443}" "code-server"
serve_tcp "${COMFYUI_TAILNET_PORT:-8188}" "${COMFYUI_LOCAL_PORT:-8188}" "ComfyUI"

if [[ "${TAILSCALE_SERVE_SEARXNG:-0}" == "1" ]]; then
  serve_tcp "${SEARXNG_TAILNET_PORT:-8889}" "${SEARXNG_LOCAL_PORT:-8889}" "SearXNG"
fi

tailscale_cli serve status
