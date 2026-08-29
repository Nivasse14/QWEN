#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

command -v python3 >/dev/null 2>&1 || die "python3 introuvable"
mkdir -p -- "$RUNTIME_DIR"
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  log "création de l'environnement Python"
  python3 -m venv "$VENV_DIR"
fi
"${VENV_DIR}/bin/python" -m pip install --upgrade pip
"${VENV_DIR}/bin/python" -m pip install -r "${SCRIPT_DIR}/requirements.txt"
log "installation terminée"
