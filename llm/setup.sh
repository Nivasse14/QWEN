#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--build] [--create-api-key] [--install-hf-cli]

Prépare les chemins natifs. --build compile llama-server avec CUDA depuis
/workspace/llama.cpp. La clé, facultative, n'est créée que sous /run.
EOF
}

build_server=0
create_api_key=0
install_hf_cli=0
while (($#)); do
  case "$1" in
    --build) build_server=1 ;;
    --create-api-key) create_api_key=1 ;;
    --install-hf-cli) install_hf_cli=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "option inconnue: $1" ;;
  esac
  shift
done

require_absolute_path "$LLAMA_MODEL_DIR"
require_absolute_path "$AI_STACK_RUNTIME_DIR"
install -d -m 0750 "$LLAMA_MODEL_DIR" "$AI_STACK_RUNTIME_DIR"

if (( create_api_key )); then
  [[ -n "$LLAMA_API_KEY_FILE" ]] || die "LLAMA_API_KEY_FILE doit être configuré"
  require_absolute_path "$LLAMA_API_KEY_FILE"
  [[ "$LLAMA_API_KEY_FILE" == /run/* ]] || die "la clé doit résider sous /run, jamais /workspace"
  install -d -m 0700 "$(dirname -- "$LLAMA_API_KEY_FILE")"
  if [[ ! -s "$LLAMA_API_KEY_FILE" ]]; then
    umask 077
    if command -v openssl >/dev/null 2>&1; then
      generated_key="sk-local-$(openssl rand -hex 32)"
    else
      require_command od
      generated_key="sk-local-$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    fi
    printf '%s\n' "$generated_key" >"$LLAMA_API_KEY_FILE"
    unset generated_key
    log "clé créée sous /run (valeur non affichée)"
  fi
  chmod 0600 "$LLAMA_API_KEY_FILE"
fi

if (( install_hf_cli )); then
  require_command python3
  python3 -m pip install --upgrade huggingface_hub
fi

if (( build_server )); then
  require_command cmake
  [[ -f "${LLAMA_CPP_SOURCE}/CMakeLists.txt" ]] || die "sources llama.cpp absentes: $LLAMA_CPP_SOURCE"
  cmake -S "$LLAMA_CPP_SOURCE" -B "${LLAMA_CPP_SOURCE}/build" \
    -DGGML_CUDA=ON -DLLAMA_CURL=ON -DCMAKE_BUILD_TYPE=Release
  cmake --build "${LLAMA_CPP_SOURCE}/build" --config Release \
    --target llama-server --parallel "${BUILD_JOBS:-$(nproc 2>/dev/null || printf '4')}"
fi

if [[ -x "$LLAMA_SERVER_BIN" ]]; then
  log "binaire prêt: $LLAMA_SERVER_BIN"
else
  log "binaire absent; relancer avec --build après installation des dépendances de compilation"
fi
log "préparation native terminée; aucun service démarré"
