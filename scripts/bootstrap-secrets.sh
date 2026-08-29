#!/usr/bin/env bash

set -Eeuo pipefail

SOURCE_DIR="${AI_PHONE_SECRET_SOURCE_DIR:-/root/.config/ai-phone-stack/secrets}"
RUNTIME_DIR="${AI_PHONE_SECRET_DIR:-/run/secrets/ai-phone-stack}"

log() {
  printf '[secrets] %s\n' "$*"
}

die() {
  printf '[secrets] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || die "ce script doit être exécuté par root"
[[ "$SOURCE_DIR" != /workspace/* ]] || die "refus de stocker un secret sur /workspace"
[[ "$RUNTIME_DIR" == /run/* ]] || die "le répertoire d'exécution doit rester sous /run"
command -v openssl >/dev/null 2>&1 || die "openssl introuvable"

umask 077
install -d -m 0700 "$SOURCE_DIR" "$RUNTIME_DIR"

generate_hex() {
  local name="$1" bytes="$2" path="${SOURCE_DIR}/$1"
  if [[ ! -s "$path" ]]; then
    openssl rand -hex "$bytes" > "$path"
    log "secret interne généré: $name"
  fi
  chmod 0600 "$path"
}

generate_password() {
  local name="$1" path="${SOURCE_DIR}/$1"
  if [[ ! -s "$path" ]]; then
    openssl rand -base64 30 | tr -d '\r\n' > "$path"
    printf '\n' >> "$path"
    log "mot de passe interne généré: $name"
  fi
  chmod 0600 "$path"
}

generate_hex webui_secret_key 32
generate_hex tools_api_token 32
generate_hex flux_orchestrator_token 32
generate_hex searxng_secret 32
generate_password code_server_password

for name in \
  webui_secret_key tools_api_token flux_orchestrator_token \
  searxng_secret code_server_password \
  github_token hf_token tailscale_auth_key llama_api_key; do
  source_path="${SOURCE_DIR}/${name}"
  [[ -s "$source_path" ]] || continue
  source_mode="$(stat -c '%a' "$source_path" 2>/dev/null || true)"
  [[ "$source_mode" =~ ^[0-7]+$ ]] || die "permissions invérifiables: $source_path"
  (( ((8#$source_mode) & 8#077) == 0 )) || die "secret trop ouvert ($source_mode): $source_path"
  install -m 0600 "$source_path" "${RUNTIME_DIR}/${name}"
done

runtime_mode="$(stat -c '%a' "$RUNTIME_DIR" 2>/dev/null || true)"
[[ "$runtime_mode" == "700" ]] || die "permissions inattendues sur $RUNTIME_DIR: $runtime_mode"
log "secrets d'exécution prêts sous /run (contenu non affiché)"
