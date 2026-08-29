#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=runpod-key-common.sh
source "${SCRIPT_DIR}/runpod-key-common.sh"

case "${1:-}" in
  "") ;;
  -h|--help)
    printf 'Usage: %s\n' "$0"
    printf 'Reads a new RunPod API key from standard input without echoing it.\n'
    exit 0
    ;;
  *)
    printf 'Usage: %s\n' "$0" >&2
    exit 2
    ;;
esac

if [[ "${SCRIPT_DIR}" == /workspace/* ]]; then
  runpod_key_error "run this local-only command from a trusted workstation, never from the Pod"
fi

key_path="$(runpod_key_file_path)"
key_dir="$(dirname -- "${key_path}")"
case "${key_path}" in
  /workspace|/workspace/*) runpod_key_error "refusing a key path under /workspace" ;;
esac
[[ ! -L "${key_dir}" ]] || runpod_key_error \
  "refusing a symlink as the key directory: ${key_dir}"
[[ ! -L "${key_path}" ]] || runpod_key_error \
  "refusing to replace a symlink: ${key_path}"
[[ ! -e "${key_path}" || -f "${key_path}" ]] || runpod_key_error \
  "key path exists but is not a regular file: ${key_path}"

umask 077
mkdir -p -- "${key_dir}"
chmod 0700 "${key_dir}"
key_dir_mode="$(runpod_file_mode "${key_dir}")" || runpod_key_error \
  "cannot verify directory permissions: ${key_dir}"
[[ "${key_dir_mode}" == "700" ]] || runpod_key_error \
  "key directory must have mode 700, found ${key_dir_mode}"

if [[ -t 0 ]]; then
  printf 'Nouvelle clé API RunPod (saisie masquée): ' >&2
  IFS= read -r -s runpod_key_value
  printf '\n' >&2
else
  IFS= read -r runpod_key_value
fi
runpod_key_value_valid "${runpod_key_value:-}" || runpod_key_error \
  "key is empty, too short, contains whitespace, or contains non-printing characters"

temporary="$(mktemp "${key_dir}/.runpod_api_key.XXXXXX")"
cleanup() {
  [[ -z "${temporary:-}" ]] || rm -f -- "${temporary}"
  unset runpod_key_value
}
on_signal() {
  local exit_code="$1"
  trap - EXIT INT TERM
  cleanup
  exit "${exit_code}"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
printf '%s\n' "${runpod_key_value}" > "${temporary}"
chmod 0600 "${temporary}"
mv -f -- "${temporary}" "${key_path}"
temporary=""
unset runpod_key_value

key_mode="$(runpod_file_mode "${key_path}")" || runpod_key_error \
  "cannot verify stored key permissions"
[[ "${key_mode}" == "600" ]] || runpod_key_error \
  "stored key mode is ${key_mode}, expected 600"
printf '[runpod-key] New key stored with mode 600 at %s\n' "${key_path}"
