#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TAILSCALE_INSTALL_DIR="${TAILSCALE_INSTALL_DIR:-${RUNTIME_DIR}/tailscale}"
TAILSCALE_BIN_DIR="${TAILSCALE_INSTALL_DIR}/bin"

ensure_stack_dirs
mkdir -p -- "${TAILSCALE_BIN_DIR}"
require_command curl
require_command tar

case "$(uname -m)" in
  x86_64|amd64) tailscale_arch="amd64" ;;
  aarch64|arm64) tailscale_arch="arm64" ;;
  *) die "Unsupported architecture for the Tailscale static build: $(uname -m)" ;;
esac

temp_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "${temp_dir}"
}
trap cleanup EXIT
mkdir -p -- "${temp_dir}/extract"

archive_path="${temp_dir}/tailscale.tgz"
download_url="https://pkgs.tailscale.com/stable/tailscale_latest_${tailscale_arch}.tgz"
log "Downloading the official Tailscale stable static build (${tailscale_arch})"
curl -fL --retry 3 --output "${archive_path}" "${download_url}"
tar -xzf "${archive_path}" -C "${temp_dir}/extract" --strip-components=1

install -m 0755 "${temp_dir}/extract/tailscale" "${TAILSCALE_BIN_DIR}/tailscale"
install -m 0755 "${temp_dir}/extract/tailscaled" "${TAILSCALE_BIN_DIR}/tailscaled"

log "Tailscale installed in ${TAILSCALE_BIN_DIR}"

