#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: HF_TOKEN=... ./download-model.sh [--force]

Télécharge uniquement le fichier GGUF configuré. Le jeton est lu depuis
l'environnement et n'est ni affiché ni écrit dans le dépôt.
EOF
}

force=0
while (($#)); do
  case "$1" in
    --force) force=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "option inconnue: $1" ;;
  esac
  shift
done

[[ -n "${HF_TOKEN:-}" ]] || die "HF_TOKEN doit être exporté dans l'environnement"
require_command hf
require_absolute_path "$LLAMA_MODEL_DIR"
install -d -m 0750 "$LLAMA_MODEL_DIR"

download_args=(
  download
  "$LLAMA_MODEL_REPO"
  "$LLAMA_MODEL_FILENAME"
  --local-dir "$LLAMA_MODEL_DIR"
)
if (( force )); then
  download_args+=(--force-download)
fi

log "téléchargement ${LLAMA_MODEL_REPO}/${LLAMA_MODEL_FILENAME}"
HF_HUB_DISABLE_TELEMETRY=1 hf "${download_args[@]}"

[[ -s "$LLAMA_MODEL_FILE" ]] || die "fichier absent ou vide après téléchargement: $LLAMA_MODEL_FILE"

if [[ -n "$LLAMA_MODEL_SHA256" ]]; then
  require_command sha256sum
  printf '%s  %s\n' "$LLAMA_MODEL_SHA256" "$LLAMA_MODEL_FILE" | sha256sum --check --status \
    || die "la somme SHA-256 du modèle ne correspond pas"
  log "somme SHA-256 vérifiée"
fi

log "modèle prêt: ${LLAMA_MODEL_FILE}"
