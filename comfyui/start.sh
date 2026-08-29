#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_command curl
require_command nohup
for path in "$COMFYUI_SOURCE_DIR" "$COMFYUI_PYTHON" "$COMFYUI_MAIN" "$COMFYUI_PID_FILE" "$COMFYUI_LOG_FILE"; do
  require_absolute_path "$path"
done
[[ -x "$COMFYUI_PYTHON" ]] || die "venv absent: exécuter ${SCRIPT_DIR}/setup.sh"
[[ -f "$COMFYUI_MAIN" ]] || die "main.py absent: $COMFYUI_MAIN"
[[ -d "$COMFYUI_GGUF_DIR" ]] || die "ComfyUI-GGUF absent: exécuter ${SCRIPT_DIR}/setup.sh"
for model in "$FLUX_UNET_PATH" "$FLUX_T5_PATH" "$FLUX_CLIP_PATH" "$FLUX_VAE_PATH"; do
  [[ -s "$model" ]] || die "modèle requis absent: $model"
done

if pidfile_process_alive "$LLAMA_PID_FILE"; then
  die "llama.cpp utilise déjà le GPU; employer ${SCRIPT_DIR}/../llm/gpu-mode.sh comfyui"
fi
"$COMFYUI_PYTHON" -c 'import gguf, torch; assert torch.cuda.is_available(), "CUDA indisponible"' \
  || die "venv ComfyUI incomplet ou sans CUDA: exécuter ${SCRIPT_DIR}/setup.sh"
if service_pid="$(comfyui_pid)"; then
  log "ComfyUI déjà actif (PID ${service_pid}); vérification de santé"
  exec "${SCRIPT_DIR}/health.sh"
fi
[[ ! -e "$COMFYUI_PID_FILE" ]] || rm -f "$COMFYUI_PID_FILE"
if curl --fail --silent --max-time 3 "${COMFYUI_URL}/system_stats" >/dev/null 2>&1; then
  die "un ComfyUI non géré répond déjà sur ${COMFYUI_URL}"
fi

case "$COMFYUI_VRAM_MODE" in
  normal) vram_args=() ;;
  lowvram) vram_args=(--lowvram --cpu-vae) ;;
  novram) vram_args=(--novram --cpu-vae) ;;
  *) die "COMFYUI_VRAM_MODE doit valoir normal, lowvram ou novram" ;;
esac

install -d -m 0750 "$AI_STACK_RUNTIME_DIR" "$COMFYUI_INPUT_DIR" "$COMFYUI_OUTPUT_DIR" "$COMFYUI_USER_DIR"
touch "$COMFYUI_LOG_FILE"
chmod 0640 "$COMFYUI_LOG_FILE" 2>/dev/null || true

comfy_args=(
  "$COMFYUI_MAIN"
  --listen "$COMFYUI_BIND_ADDRESS"
  --port "$COMFYUI_PORT"
  --disable-auto-launch
  --preview-method none
  --input-directory "$COMFYUI_INPUT_DIR"
  --output-directory "$COMFYUI_OUTPUT_DIR"
  --user-directory "$COMFYUI_USER_DIR"
  "${vram_args[@]}"
)

log "démarrage natif de ComfyUI sur ${COMFYUI_BIND_ADDRESS}:${COMFYUI_PORT}"
(
  cd "$COMFYUI_SOURCE_DIR"
  nohup env PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    "$COMFYUI_PYTHON" "${comfy_args[@]}" >>"$COMFYUI_LOG_FILE" 2>&1 </dev/null &
  printf '%s\n' "$!" >"${COMFYUI_PID_FILE}.$$"
)
mv -f "${COMFYUI_PID_FILE}.$$" "$COMFYUI_PID_FILE"
service_pid="$(pid_from_file "$COMFYUI_PID_FILE")"
sleep 1
if ! pid_is_alive "$service_pid"; then
  tail -n 150 "$COMFYUI_LOG_FILE" >&2 || true
  rm -f "$COMFYUI_PID_FILE"
  die "ComfyUI s'est arrêté immédiatement"
fi
if ! wait_for_http "${COMFYUI_URL}/system_stats" "$COMFYUI_START_TIMEOUT"; then
  tail -n 150 "$COMFYUI_LOG_FILE" >&2 || true
  "${SCRIPT_DIR}/stop.sh" || true
  die "ComfyUI n'est pas devenu sain"
fi
"${SCRIPT_DIR}/health.sh"
