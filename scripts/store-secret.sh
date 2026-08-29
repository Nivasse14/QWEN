#!/usr/bin/env bash

set -Eeuo pipefail

SOURCE_DIR="${AI_PHONE_SECRET_SOURCE_DIR:-/root/.config/ai-phone-stack/secrets}"
name="${1:-}"
case "$name" in
  github_token|hf_token|tailscale_auth_key|llama_api_key) ;;
  *)
    printf 'Usage: %s {github_token|hf_token|tailscale_auth_key|llama_api_key}\n' "$0" >&2
    exit 2
    ;;
esac
[[ "$(id -u)" -eq 0 ]] || { printf 'root requis\n' >&2; exit 1; }
[[ "$SOURCE_DIR" != /workspace/* ]] || { printf 'refus de /workspace\n' >&2; exit 1; }

umask 077
install -d -m 0700 "$SOURCE_DIR"
IFS= read -r -s secret_value
printf '\n' >&2
[[ -n "$secret_value" ]] || { printf 'secret vide refusé\n' >&2; exit 1; }
temporary="${SOURCE_DIR}/.${name}.$$"
printf '%s\n' "$secret_value" > "$temporary"
chmod 0600 "$temporary"
mv -f "$temporary" "${SOURCE_DIR}/${name}"
unset secret_value
printf '[secrets] %s enregistré sans affichage\n' "$name"
