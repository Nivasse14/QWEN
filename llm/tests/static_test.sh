#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LLM_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
COMFYUI_DIR="$(cd -- "${LLM_DIR}/../comfyui" && pwd -P)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_text() {
  local needle="$1"
  local file="$2"
  grep -F -- "$needle" "$file" >/dev/null || fail "texte absent de ${file}: ${needle}"
}

while IFS= read -r script; do
  bash -n "$script" || fail "syntaxe shell invalide: $script"
done < <(find "$LLM_DIR" -maxdepth 2 -type f -name '*.sh' -print | sort)

assert_text 'LLAMA_BIND_ADDRESS="${LLAMA_BIND_ADDRESS:-127.0.0.1}"' "${LLM_DIR}/common.sh"
assert_text 'LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-${LLAMA_CPP_SOURCE}/build/bin/llama-server}"' "${LLM_DIR}/common.sh"
assert_text 'LLAMA_CONTEXT_SIZE="${LLAMA_CONTEXT_SIZE:-16384}"' "${LLM_DIR}/common.sh"
assert_text 'LLAMA_ALIAS="${LLAMA_ALIAS:-qwen3.8-uncensored}"' "${LLM_DIR}/common.sh"
assert_text 'LLAMA_API_KEY_FILE="${LLAMA_API_KEY_FILE:-/run/secrets/ai-phone-stack/llama_api_key}"' "${LLM_DIR}/common.sh"
assert_text '--flash-attn on' "${LLM_DIR}/start.sh"
assert_text '--cache-type-k q8_0' "${LLM_DIR}/start.sh"
assert_text '--cache-type-v q8_0' "${LLM_DIR}/start.sh"
assert_text '--chat-template-kwargs' "${LLM_DIR}/start.sh"
assert_text '{"enable_thinking":false}' "${LLM_DIR}/start.sh"
assert_text '--reasoning-budget 0' "${LLM_DIR}/start.sh"
assert_text 'server_args+=(--api-key-file "$LLAMA_API_KEY_FILE")' "${LLM_DIR}/start.sh"
assert_text 'nohup "$LLAMA_SERVER_BIN"' "${LLM_DIR}/start.sh"
assert_text 'printf ' "${LLM_DIR}/start.sh"
assert_text '"${LLAMA_BASE_URL}/health"' "${LLM_DIR}/health.sh"
assert_text '"${LLAMA_BASE_URL}/v1/models"' "${LLM_DIR}/health.sh"
assert_text 'gpu-switch.lock' "${LLM_DIR}/gpu-mode.sh"
assert_text '"${COMFYUI_DIR}/stop.sh"' "${LLM_DIR}/gpu-mode.sh"
assert_text 'state="${rest%% *}"' "${LLM_DIR}/common.sh"
assert_text '"$owner_host" != "$current_host"' "${LLM_DIR}/gpu-mode.sh"

if grep -R -E --include='*' \
  '(github_pat_[A-Za-z0-9_]{10,}|ghp_[A-Za-z0-9]{10,}|hf_[A-Za-z0-9]{20,}|rpa_[A-Za-z0-9]{10,}|tskey-[A-Za-z0-9-]{10,})' \
  "$LLM_DIR" "$COMFYUI_DIR" >/dev/null; then
  fail "un motif ressemblant à un secret est présent dans les fichiers"
fi

if grep -R -F --exclude='static_test.sh' '/workspace/secrets' "$LLM_DIR" >/dev/null; then
  fail "un secret ne doit jamais être stocké sur le FUSE /workspace"
fi

if find "$LLM_DIR" -type f ! -path '*/tests/*' -print0 \
  | xargs -0 grep -i -F 'docker' >/dev/null 2>&1; then
  fail "le lifecycle LLM natif ne doit dépendre d'aucun Docker"
fi

printf 'OK: llama.cpp natif, santé, secrets et mutex GPU\n'
