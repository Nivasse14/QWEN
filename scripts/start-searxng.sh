#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SEARXNG_SOURCE_DIR="${SEARXNG_SOURCE_DIR:-${VENDOR_DIR}/searxng}"
SEARXNG_VENV_DIR="${SEARXNG_VENV_DIR:-${RUNTIME_DIR}/searxng-venv}"
SEARXNG_SETTINGS_PATH="${SEARXNG_SETTINGS_PATH:-${STACK_ROOT}/config/searxng/settings.yml}"

if [[ -z "${SEARXNG_SECRET:-}" && -n "${SEARXNG_SECRET_FILE:-}" ]]; then
  SEARXNG_SECRET="$(read_secret_file "${SEARXNG_SECRET_FILE}")"
fi
[[ -n "${SEARXNG_SECRET:-}" ]] || die \
  "Set SEARXNG_SECRET or SEARXNG_SECRET_FILE; never store it in settings.yml"
[[ "${#SEARXNG_SECRET}" -ge 32 ]] || die "SEARXNG_SECRET must contain at least 32 characters"
[[ -x "${SEARXNG_VENV_DIR}/bin/granian" ]] || die \
  "SearXNG is not installed; run scripts/setup-searxng.sh first"
[[ -f "${SEARXNG_SOURCE_DIR}/searx/webapp.py" ]] || die \
  "SearXNG source not found at ${SEARXNG_SOURCE_DIR}"
[[ -r "${SEARXNG_SETTINGS_PATH}" ]] || die \
  "Settings file not found: ${SEARXNG_SETTINGS_PATH}"

export SEARXNG_SETTINGS_PATH SEARXNG_SECRET
export GRANIAN_INTERFACE="wsgi"
export GRANIAN_HOST="${SEARXNG_HOST:-127.0.0.1}"
export GRANIAN_PORT="${SEARXNG_PORT:-8889}"
export GRANIAN_WORKERS="${SEARXNG_WORKERS:-1}"
export GRANIAN_BLOCKING_THREADS="${SEARXNG_BLOCKING_THREADS:-4}"
export GRANIAN_WEBSOCKETS="false"

log "Starting SearXNG on ${GRANIAN_HOST}:${GRANIAN_PORT}"
cd -- "${SEARXNG_SOURCE_DIR}"
exec "${SEARXNG_VENV_DIR}/bin/granian" searx.webapp:app
