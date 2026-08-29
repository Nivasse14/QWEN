#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SEARXNG_SOURCE_DIR="${SEARXNG_SOURCE_DIR:-${VENDOR_DIR}/searxng}"
SEARXNG_VENV_DIR="${SEARXNG_VENV_DIR:-${RUNTIME_DIR}/searxng-venv}"
SEARXNG_REF="${SEARXNG_REF:-master}"

install_system_packages() {
  if [[ "$(id -u)" -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
    log "Installing SearXNG build prerequisites"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential git python3-dev python3-pip python3-venv \
      libffi-dev libssl-dev libxslt1-dev zlib1g-dev
  else
    warn "Not installing OS packages (root + apt-get required); checking existing tools"
    require_command git
    require_command python3
  fi
}

ensure_stack_dirs
install_system_packages

if [[ ! -d "${SEARXNG_SOURCE_DIR}/.git" ]]; then
  log "Cloning SearXNG into persistent storage"
  git clone --depth 1 --branch "${SEARXNG_REF}" \
    https://github.com/searxng/searxng.git "${SEARXNG_SOURCE_DIR}"
elif [[ "${SEARXNG_UPDATE:-0}" == "1" ]]; then
  log "Updating the existing SearXNG checkout"
  git -C "${SEARXNG_SOURCE_DIR}" fetch --depth 1 origin "${SEARXNG_REF}"
  git -C "${SEARXNG_SOURCE_DIR}" checkout "${SEARXNG_REF}"
  git -C "${SEARXNG_SOURCE_DIR}" pull --ff-only origin "${SEARXNG_REF}"
else
  log "Keeping the existing SearXNG checkout (set SEARXNG_UPDATE=1 to update it)"
fi

if [[ ! -x "${SEARXNG_VENV_DIR}/bin/python" ]]; then
  log "Creating the persistent Python environment"
  python3 -m venv "${SEARXNG_VENV_DIR}"
fi

"${SEARXNG_VENV_DIR}/bin/python" -m pip install --upgrade pip setuptools wheel
"${SEARXNG_VENV_DIR}/bin/python" -m pip install \
  pyyaml msgspec typing-extensions pybind11
"${SEARXNG_VENV_DIR}/bin/python" -m pip install \
  --use-pep517 --no-build-isolation --editable "${SEARXNG_SOURCE_DIR}"
"${SEARXNG_VENV_DIR}/bin/python" -m pip install granian

log "SearXNG is installed. Start it with scripts/start-searxng.sh"

