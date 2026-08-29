#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

[[ -x "${VENV_DIR}/bin/uvicorn" ]] || die "exécuter setup.sh d'abord"
export TOOLS_API_BEARER_TOKEN
export GITHUB_TOKEN
export FLUX_ORCHESTRATOR_TOKEN
TOOLS_API_BEARER_TOKEN="$(read_private_secret "${SECRET_DIR}/tools_api_token")"
GITHUB_TOKEN="$(read_private_secret "${SECRET_DIR}/github_token")"
FLUX_ORCHESTRATOR_TOKEN="$(read_private_secret "${SECRET_DIR}/flux_orchestrator_token")"
[[ ${#TOOLS_API_BEARER_TOKEN} -ge 24 ]] || die "tools_api_token trop court"
[[ ${#FLUX_ORCHESTRATOR_TOKEN} -ge 24 ]] || die "flux_orchestrator_token trop court"
[[ -n "${GITHUB_ALLOWED_REPOS:-}" ]] || die "GITHUB_ALLOWED_REPOS est vide"

export PYTHONPATH="${SCRIPT_DIR}"
export REPOS_ROOT="${REPOS_ROOT:-/workspace/repos}"
export FLUX_ORCHESTRATOR_URL="${FLUX_ORCHESTRATOR_URL:-http://127.0.0.1:8003/v1/images/generations}"
exec "${VENV_DIR}/bin/uvicorn" tools_api.asgi:app \
  --host 127.0.0.1 \
  --port "${TOOLS_API_PORT:-8002}" \
  --no-access-log
