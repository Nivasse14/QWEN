#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_command curl
require_command nohup
require_absolute_path "$LLAMA_SERVER_BIN"
require_absolute_path "$LLAMA_MODEL_FILE"
require_absolute_path "$LLAMA_PID_FILE"
require_absolute_path "$LLAMA_LOG_FILE"

[[ -x "$LLAMA_SERVER_BIN" ]] || die "binaire natif introuvable ou non exécutable: $LLAMA_SERVER_BIN"
[[ -s "$LLAMA_MODEL_FILE" ]] || die "modèle introuvable: $LLAMA_MODEL_FILE"

if pidfile_process_alive "$COMFYUI_PID_FILE"; then
  die "ComfyUI utilise déjà le GPU; employer ${SCRIPT_DIR}/gpu-mode.sh llm"
fi

if service_pid="$(llama_pid)"; then
  recorded_pid="$(pid_from_file "$LLAMA_PID_FILE" 2>/dev/null || true)"
  if [[ "$recorded_pid" != "$service_pid" ]]; then
    install -d -m 0750 "$AI_STACK_RUNTIME_DIR"
    printf '%s\n' "$service_pid" >"$LLAMA_PID_FILE"
    log "processus llama-server natif existant adopté (PID ${service_pid})"
  fi
  log "llama.cpp déjà actif (PID ${service_pid}); vérification de santé"
  exec "${SCRIPT_DIR}/health.sh"
fi

if [[ -e "$LLAMA_PID_FILE" ]]; then
  log "suppression du PID périmé ${LLAMA_PID_FILE}"
  rm -f "$LLAMA_PID_FILE"
fi

if curl --fail --silent --max-time 3 "${LLAMA_BASE_URL}/health" >/dev/null 2>&1; then
  die "un serveur non géré répond déjà sur ${LLAMA_BASE_URL}; l'arrêter avant ce démarrage"
fi

install -d -m 0750 "$AI_STACK_RUNTIME_DIR"
touch "$LLAMA_LOG_FILE"
chmod 0640 "$LLAMA_LOG_FILE" 2>/dev/null || true

resolved_context_size="$(resolve_llama_context_size)"
gpu_memory_mib="$(detect_total_gpu_memory_mib 2>/dev/null || true)"
if [[ "$resolved_context_size" == "65536" \
  && "$gpu_memory_mib" =~ ^[0-9]+$ \
  && "$gpu_memory_mib" -lt "$LLAMA_64K_MIN_GPU_MEMORY_MIB" ]]; then
  log "AVERTISSEMENT: contexte 64K forcé avec seulement ${gpu_memory_mib} MiB de VRAM; risque d'OOM"
fi

server_args=(
  --model "$LLAMA_MODEL_FILE"
  --host "$LLAMA_BIND_ADDRESS"
  --port "$LLAMA_PORT"
  --alias "$LLAMA_ALIAS"
  --ctx-size "$resolved_context_size"
  --n-gpu-layers "$LLAMA_GPU_LAYERS"
  --flash-attn on
  --cache-type-k q8_0
  --cache-type-v q8_0
  --jinja
  --chat-template-kwargs '{"enable_thinking":false,"preserve_thinking":false}'
  --reasoning off
  --reasoning-budget 0
  --no-context-shift
  --parallel "$LLAMA_PARALLEL"
  --metrics
)

if api_key="$(first_api_key 2>/dev/null)" && [[ -n "$api_key" ]]; then
  unset api_key
  require_absolute_path "$LLAMA_API_KEY_FILE"
  [[ "$LLAMA_API_KEY_FILE" == /run/* ]] \
    || die "la clé API doit être matérialisée sous /run: $LLAMA_API_KEY_FILE"
  server_args+=(--api-key-file "$LLAMA_API_KEY_FILE")
  log "authentification activée via un fichier sous /run"
elif [[ "$LLAMA_REQUIRE_API_KEY" == "1" ]]; then
  die "clé API requise mais absente: ${LLAMA_API_KEY_FILE:-non configuré}"
else
  log "clé API absente: service local uniquement, sans authentification"
fi

log "démarrage natif de llama.cpp sur ${LLAMA_BIND_ADDRESS}:${LLAMA_PORT}, contexte ${resolved_context_size}, raisonnement désactivé"
nohup "$LLAMA_SERVER_BIN" "${server_args[@]}" >>"$LLAMA_LOG_FILE" 2>&1 </dev/null &
service_pid=$!
pid_tmp="${LLAMA_PID_FILE}.$$"
printf '%s\n' "$service_pid" >"$pid_tmp"
mv -f "$pid_tmp" "$LLAMA_PID_FILE"

sleep 1
if ! pid_is_alive "$service_pid"; then
  tail -n 100 "$LLAMA_LOG_FILE" >&2 || true
  rm -f "$LLAMA_PID_FILE"
  die "llama-server s'est arrêté immédiatement"
fi

if ! wait_for_http "${LLAMA_BASE_URL}/health" "$LLAMA_START_TIMEOUT"; then
  log "llama.cpp n'est pas devenu sain; derniers journaux:"
  tail -n 100 "$LLAMA_LOG_FILE" >&2 || true
  "${SCRIPT_DIR}/stop.sh" || true
  die "échec du démarrage"
fi

"${SCRIPT_DIR}/health.sh"
