#!/usr/bin/env bash

set -Eeuo pipefail
OPENWEBUI_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

for script in common.sh run.sh start.sh stop.sh health.sh; do
  bash -n "${OPENWEBUI_DIR}/${script}"
done

PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/ai-phone-openwebui-pycache" \
  python3 -m py_compile "${OPENWEBUI_DIR}/configure-model.py"

grep -Fq 'export ENABLE_PERSISTENT_CONFIG=false' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'OPENWEBUI_REQUIRED_VERSION=0.11.1' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'export ENABLE_OPENAI_API_PASSTHROUGH=false' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'OPENAI_API_BASE_URLS=http://127.0.0.1:8000/v1' \
  "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'LLAMA_CONTEXT_SIZE_EFFECTIVE="$(bash "${STACK_ROOT}/llm/context-size.sh")"' \
  "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'CONTEXT_COMPACTION_RESERVE=$((LLAMA_CONTEXT_SIZE_EFFECTIVE / 4))' \
  "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'CONTEXT_COMPACTION_RESERVE < 12288' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'CONTEXT_COMPACTION_THRESHOLD=$((LLAMA_CONTEXT_SIZE_EFFECTIVE - CONTEXT_COMPACTION_RESERVE))' \
  "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'export ENABLE_CONTEXT_COMPACTION=true' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'export CONTEXT_COMPACTION_MODEL=qwen3.8-uncensored' \
  "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'export RAG_FULL_CONTEXT=false' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'export BYPASS_EMBEDDING_AND_RETRIEVAL=false' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'export RAG_TOP_K=3' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'export CHUNK_SIZE=1000' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'export WEB_FETCH_MAX_CONTENT_LENGTH=6000' "${OPENWEBUI_DIR}/run.sh"
grep -Fq '"max_tokens": 4096' "${OPENWEBUI_DIR}/configure-model.py"

context_threshold() {
  local context_size="$1"
  local reserve=$((context_size / 4))
  (( reserve >= 12288 )) || reserve=12288
  printf '%s\n' "$((context_size - reserve))"
}
[[ "$(context_threshold 32768)" == "20480" ]]
[[ "$(context_threshold 49152)" == "36864" ]]
[[ "$(context_threshold 65536)" == "49152" ]]
(( $(context_threshold 32768) + 4096 < 32768 ))
(( $(context_threshold 49152) + 4096 < 49152 ))
(( $(context_threshold 65536) + 4096 < 65536 ))
grep -Fq '"auth_type": "bearer"' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'serve --host 127.0.0.1' "${OPENWEBUI_DIR}/run.sh"
grep -Fq 'SECRET_DIR="${AI_PHONE_SECRET_DIR:-/run/secrets/ai-phone-stack}"' \
  "${OPENWEBUI_DIR}/common.sh"

SYSTEM_PROMPT="${OPENWEBUI_DIR}/system-prompt.txt"
grep -Fq -- '- execute_code :' "$SYSTEM_PROMPT"
grep -Fq -- '- github_* :' "$SYSTEM_PROMPT"
grep -Fq -- '- server_shell :' "$SYSTEM_PROMPT"
grep -Fq -- '- generate_image :' "$SYSTEM_PROMPT"
grep -Fq -- '- flux_image :' "$SYSTEM_PROMPT"
grep -Fq 'utilise generate_image et non' "$SYSTEM_PROMPT"

if grep -Eq 'ai_phone_(github|server_shell|flux_image)' "$SYSTEM_PROMPT"; then
  printf 'Obsolete OpenAPI tool names found in system prompt\n' >&2
  exit 1
fi

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
