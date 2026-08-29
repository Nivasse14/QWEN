#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: HF_TOKEN=... ./download-models.sh [--force]

Télécharge FLUX.1-dev GGUF Q5_K_S, T5 GGUF Q4_K_M, CLIP-L et le VAE.
Le dépôt black-forest-labs/FLUX.1-dev est soumis à acceptation de licence sur
Hugging Face. Le jeton reste exclusivement dans l'environnement.
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

download_one() {
  local repo="$1"
  local filename="$2"
  local destination="$3"
  local expected_sha256="$4"
  local destination_dir
  local -a args

  destination_dir="$(dirname -- "$destination")"
  require_absolute_path "$destination"
  [[ "$(basename -- "$destination")" == "$filename" ]] \
    || die "le nom de destination doit correspondre au fichier HF: ${filename}"
  install -d -m 0750 "$destination_dir"

  args=(download "$repo" "$filename" --local-dir "$destination_dir")
  if (( force )); then
    args+=(--force-download)
  fi

  log "téléchargement ${repo}/${filename}"
  if ! HF_HUB_DISABLE_TELEMETRY=1 hf "${args[@]}"; then
    if [[ "$repo" == "black-forest-labs/FLUX.1-dev" ]]; then
      die "échec VAE: accepter la licence FLUX.1-dev sur Hugging Face et vérifier HF_TOKEN"
    fi
    die "échec du téléchargement ${repo}/${filename}"
  fi

  [[ -s "$destination" ]] || die "fichier absent ou vide: $destination"
  if [[ -n "$expected_sha256" ]]; then
    require_command sha256sum
    printf '%s  %s\n' "$expected_sha256" "$destination" | sha256sum --check --status \
      || die "somme SHA-256 incorrecte pour $destination"
  fi
}

download_one "$FLUX_UNET_REPO" "$FLUX_UNET_FILENAME" "$FLUX_UNET_PATH" "$FLUX_UNET_SHA256"
download_one "$FLUX_T5_REPO" "$FLUX_T5_FILENAME" "$FLUX_T5_PATH" "$FLUX_T5_SHA256"
download_one "$FLUX_CLIP_REPO" "$FLUX_CLIP_FILENAME" "$FLUX_CLIP_PATH" "$FLUX_CLIP_SHA256"
download_one "$FLUX_VAE_REPO" "$FLUX_VAE_FILENAME" "$FLUX_VAE_PATH" "$FLUX_VAE_SHA256"

log "les quatre composants FLUX sont prêts"
