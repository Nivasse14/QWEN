#!/usr/bin/env bash

set -Eeuo pipefail
OPENWEBUI_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

for script in common.sh run.sh start.sh stop.sh health.sh; do
  bash -n "${OPENWEBUI_DIR}/${script}"
done

PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/ai-phone-openwebui-pycache" \
  python3 -m py_compile "${OPENWEBUI_DIR}/configure-model.py"

grep -Fq 'export ENABLE_PERSISTENT_CONFIG=false' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'export ENABLE_OPENAI_API_PASSTHROUGH=false' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'OPENAI_API_BASE_URLS=http://127.0.0.1:8000/v1' \
  "${OPENWEBUI_DIR}/run.sh"
grep -Fq '"auth_type": "bearer"' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'serve --host 127.0.0.1' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'SECRET_DIR="${AI_PHONE_SECRET_DIR:-/run/secrets/ai-phone-stack}"' \
  "${OPENWEBUI_DIR}/common.sh"

if grep -Eq '(github_pat_|ghp_|rpa_[[:alnum:]]|hf_[[:alnum:]]|tskey-)' \
  "${OPENWEBUI_DIR}/common.sh" \
  "${OPENWEBUI_DIR}/run.sh" \
  "${OPENWEBUI_DIR}/start.sh" \
  "${OPENWEBUI_DIR}/stop.sh" \
  "${OPENWEBUI_DIR}/health.sh" \
  "${OPENWEBUI_DIR}/configure-model.py" \
  "${OPENWEBUI_DIR}/system-prompt.txt"; then
  printf 'A token-like literal was found in Open WebUI configuration\n' >&2
  exit 1
fi

printf 'Open WebUI static checks: ok\n'
