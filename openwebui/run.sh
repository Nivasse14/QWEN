#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

OPENWEBUI_BIN="${OPENWEBUI_VENV_DIR}/bin/open-webui"
[[ -x "$OPENWEBUI_BIN" ]] || die "open-webui introuvable: $OPENWEBUI_BIN"

export WEBUI_SECRET_KEY TOOLS_API_TOKEN FLUX_ORCHESTRATOR_TOKEN
WEBUI_SECRET_KEY="$(read_private_secret "${SECRET_DIR}/webui_secret_key")"
TOOLS_API_TOKEN="$(read_private_secret "${SECRET_DIR}/tools_api_token")"
FLUX_ORCHESTRATOR_TOKEN="$(read_private_secret "${SECRET_DIR}/flux_orchestrator_token")"
[[ ${#WEBUI_SECRET_KEY} -ge 32 ]] || die "webui_secret_key trop courte"

if [[ -s "${SECRET_DIR}/llama_api_key" ]]; then
  OPENAI_LOCAL_KEY="$(read_private_secret "${SECRET_DIR}/llama_api_key")"
else
  OPENAI_LOCAL_KEY="local-loopback-only"
fi

TOOL_SERVER_CONNECTIONS="$(${OPENWEBUI_VENV_DIR}/bin/python - <<'PY'
import json, os
print(json.dumps([{
    "type": "openapi",
    "url": "http://127.0.0.1:8002",
    "spec_type": "url",
    "spec": "",
    "path": "openapi.json",
    "auth_type": "bearer",
    "key": os.environ["TOOLS_API_TOKEN"],
    "config": {"enable": True},
    "info": {
        "id": "ai_phone",
        "name": "AI Phone Tools",
        "description": "GitHub, diagnostics serveur et génération FLUX privée"
    }
}], ensure_ascii=False))
PY
)"
export TOOL_SERVER_CONNECTIONS

export DATA_DIR="$OPENWEBUI_DATA_DIR"
export ENV=prod
export ENABLE_PERSISTENT_CONFIG=false
export WEBUI_AUTH=true
export ENABLE_SIGNUP=false
export DEFAULT_USER_ROLE=pending
export ENABLE_PASSWORD_VALIDATION=true
export JWT_EXPIRES_IN=7d
export ENABLE_VALVE_ENCRYPTION=true
export WEBUI_NAME="IA Mobile"
export DEFAULT_LOCALE=fr-FR

export ENABLE_OPENAI_API=true
export OPENAI_API_BASE_URLS=http://127.0.0.1:8000/v1
export OPENAI_API_KEYS="$OPENAI_LOCAL_KEY"
export OPENAI_API_CONFIGS='{"0":{"enable":true,"model_ids":["qwen3.8-uncensored"],"tags":["local","uncensored"]}}'
export DEFAULT_MODELS=qwen3.8-uncensored-agent
export DEFAULT_PINNED_MODELS=qwen3.8-uncensored-agent
export TASK_MODEL_EXTERNAL=qwen3.8-uncensored
export ENABLE_OPENAI_API_PASSTHROUGH=false

export ENABLE_WEB_SEARCH=true
export WEB_SEARCH_ENGINE=searxng
export 'SEARXNG_QUERY_URL=http://127.0.0.1:8889/search?q=<query>'
export SEARXNG_LANGUAGE=fr-FR
export WEB_SEARCH_RESULT_COUNT=5
export WEB_FETCH_MAX_CONTENT_LENGTH=30000

export ENABLE_CODE_INTERPRETER=true
export CODE_INTERPRETER_ENGINE=pyodide

export ENABLE_DIRECT_CONNECTIONS=true
export ENABLE_FORWARD_USER_INFO_HEADERS=false

export ENABLE_IMAGE_GENERATION=true
export IMAGE_GENERATION_ENGINE=openai
export IMAGE_GENERATION_MODEL=flux1-dev-gguf
export IMAGE_SIZE=1280x720
export IMAGE_STEPS=20
export ENABLE_IMAGE_EDIT=false
export IMAGES_OPENAI_API_BASE_URL=http://127.0.0.1:8003/v1
export IMAGES_OPENAI_API_KEY="$FLUX_ORCHESTRATOR_TOKEN"

install -d -m 0700 "$PRIVATE_WORK_DIR"
mkdir -p -- "$OPENWEBUI_DATA_DIR"
cd -- "$PRIVATE_WORK_DIR"
exec "$OPENWEBUI_BIN" serve --host 127.0.0.1 --port "${OPENWEBUI_PORT:-3000}"
