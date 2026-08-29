#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--update-source] [--update-node] [--skip-python-deps]

Installe les sources ComfyUI, ComfyUI-GGUF et un venv natif héritant du PyTorch
du template RunPod. Aucun service n'est démarré.
EOF
}

update_source=0
update_node=0
skip_python_deps=0
while (($#)); do
  case "$1" in
    --update-source) update_source=1 ;;
    --update-node) update_node=1 ;;
    --skip-python-deps) skip_python_deps=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "option inconnue: $1" ;;
  esac
  shift
done

require_command git
require_command python3
require_absolute_path "$COMFYUI_SOURCE_DIR"
require_absolute_path "$COMFYUI_VENV_DIR"
install -d -m 0750 "$(dirname -- "$COMFYUI_SOURCE_DIR")" "$(dirname -- "$COMFYUI_VENV_DIR")"

if [[ -d "${COMFYUI_SOURCE_DIR}/.git" ]]; then
  if (( update_source )); then
    git -C "$COMFYUI_SOURCE_DIR" fetch --depth 1 origin "$COMFYUI_REF"
    git -C "$COMFYUI_SOURCE_DIR" checkout --detach FETCH_HEAD
  fi
elif [[ -f "$COMFYUI_MAIN" ]]; then
  log "sources ComfyUI existantes conservées"
elif [[ -e "$COMFYUI_SOURCE_DIR" ]]; then
  die "répertoire ComfyUI incomplet: $COMFYUI_SOURCE_DIR"
else
  git clone --depth 1 --branch "$COMFYUI_REF" "$COMFYUI_REPO" "$COMFYUI_SOURCE_DIR"
fi

install -d -m 0750 \
  "${COMFYUI_MODELS_DIR}/unet" "${COMFYUI_MODELS_DIR}/text_encoders" \
  "${COMFYUI_MODELS_DIR}/vae" "$COMFYUI_CUSTOM_NODES_DIR" \
  "$COMFYUI_INPUT_DIR" "$COMFYUI_OUTPUT_DIR" "$COMFYUI_USER_DIR"

if [[ -d "${COMFYUI_GGUF_DIR}/.git" ]]; then
  if (( update_node )); then
    git -C "$COMFYUI_GGUF_DIR" fetch --depth 1 origin "$COMFYUI_GGUF_REF"
    git -C "$COMFYUI_GGUF_DIR" checkout --detach FETCH_HEAD
  fi
elif [[ -e "$COMFYUI_GGUF_DIR" ]]; then
  die "ComfyUI-GGUF existe mais n'est pas un dépôt Git: $COMFYUI_GGUF_DIR"
else
  git clone --depth 1 --branch "$COMFYUI_GGUF_REF" \
    "$COMFYUI_GGUF_REPO" "$COMFYUI_GGUF_DIR"
fi

if [[ ! -x "$COMFYUI_PYTHON" ]]; then
  python3 -m venv --system-site-packages "$COMFYUI_VENV_DIR"
fi

if (( ! skip_python_deps )); then
  "$COMFYUI_PYTHON" -m pip install --upgrade pip wheel
  "$COMFYUI_PYTHON" -m pip install -r "${COMFYUI_SOURCE_DIR}/requirements.txt"
  "$COMFYUI_PYTHON" -m pip install -r "${COMFYUI_GGUF_DIR}/requirements.txt"
fi

"$COMFYUI_PYTHON" -c 'import gguf, torch; assert torch.cuda.is_available(), "CUDA indisponible dans le venv ComfyUI"'
log "préparation native terminée; aucun service démarré"
