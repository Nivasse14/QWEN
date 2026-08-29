#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_command curl
service_pid="$(orchestrator_pid)" || die "orchestrateur non actif ou PID non géré"
curl --fail --silent --show-error --max-time 10 "${FLUX_ORCHESTRATOR_BASE_URL}/health"
printf '\n'
