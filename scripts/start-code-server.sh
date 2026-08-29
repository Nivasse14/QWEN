#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CODE_SERVER_VERSION="${CODE_SERVER_VERSION:-4.135.0}"
CODE_SERVER_PREFIX="${CODE_SERVER_PREFIX:-${RUNTIME_DIR}/code-server-${CODE_SERVER_VERSION}}"
CODE_SERVER_EXTENSIONS_DIR="${CODE_SERVER_EXTENSIONS_DIR:-${RUNTIME_DIR}/code-server-extensions}"
CODE_SERVER_PRIVATE_DIR="${CODE_SERVER_PRIVATE_DIR:-/var/lib/ai-phone-stack/code-server}"
CODE_SERVER_USER_DATA_DIR="${CODE_SERVER_USER_DATA_DIR:-${CODE_SERVER_PRIVATE_DIR}/user-data}"
CODE_SERVER_PRIVATE_HOME="${CODE_SERVER_PRIVATE_HOME:-${CODE_SERVER_PRIVATE_DIR}/home}"
CODE_SERVER_SETTINGS_TEMPLATE="${CODE_SERVER_SETTINGS_TEMPLATE:-${STACK_ROOT}/config/code-server/settings.json}"
CODE_SERVER_RUN_DIR="${CODE_SERVER_RUN_DIR:-/run/ai-phone-stack/code-server}"
CODE_SERVER_CONFIG_FILE="${CODE_SERVER_CONFIG_FILE:-${CODE_SERVER_RUN_DIR}/config.yaml}"
CODE_SERVER_PASSWORD_FILE="${CODE_SERVER_PASSWORD_FILE:-${AI_PHONE_SECRET_DIR:-/run/secrets/ai-phone-stack}/code_server_password}"
CODE_SERVER_PORT="${CODE_SERVER_PORT:-8443}"

require_private_path() {
  local path="$1" label="$2"
  [[ "$path" == /* ]] || die "${label} must be an absolute path"
  case "$path" in
    /workspace|/workspace/*)
      die "${label} must stay outside /workspace because it may contain credentials"
      ;;
  esac
}

for private_pair in \
  "$CODE_SERVER_PRIVATE_DIR:CODE_SERVER_PRIVATE_DIR" \
  "$CODE_SERVER_USER_DATA_DIR:CODE_SERVER_USER_DATA_DIR" \
  "$CODE_SERVER_PRIVATE_HOME:CODE_SERVER_PRIVATE_HOME" \
  "$CODE_SERVER_RUN_DIR:CODE_SERVER_RUN_DIR" \
  "$CODE_SERVER_CONFIG_FILE:CODE_SERVER_CONFIG_FILE"; do
  require_private_path "${private_pair%%:*}" "${private_pair#*:}"
done
[[ "$CODE_SERVER_PORT" =~ ^[0-9]+$ ]] \
  && (( CODE_SERVER_PORT >= 1 && CODE_SERVER_PORT <= 65535 )) \
  || die "CODE_SERVER_PORT must be between 1 and 65535"

find_code_server() {
  if [[ -x "${CODE_SERVER_PREFIX}/bin/code-server" ]]; then
    printf '%s\n' "${CODE_SERVER_PREFIX}/bin/code-server"
    return 0
  fi
  local candidate
  for candidate in "${CODE_SERVER_PREFIX}"/lib/code-server-*/bin/code-server; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

if [[ -z "${CODE_SERVER_PASSWORD:-}" ]]; then
  CODE_SERVER_PASSWORD="$(read_secret_file "$CODE_SERVER_PASSWORD_FILE")"
fi
[[ ${#CODE_SERVER_PASSWORD} -ge 16 ]] \
  || die "code-server password must contain at least 16 characters"

CODE_SERVER_BIN="$(find_code_server)" \
  || die "code-server is not installed; run scripts/setup-code-server.sh first"
CODE_WORKSPACE="${CODE_WORKSPACE:-/workspace}"
if [[ ! -d "$CODE_WORKSPACE" ]]; then
  warn "${CODE_WORKSPACE} does not exist; opening ${STACK_ROOT} instead"
  CODE_WORKSPACE="$STACK_ROOT"
fi

require_command python3
umask 077
install -d -m 0700 \
  "$CODE_SERVER_PRIVATE_DIR" \
  "$CODE_SERVER_USER_DATA_DIR" \
  "$CODE_SERVER_PRIVATE_HOME" \
  "$CODE_SERVER_RUN_DIR" \
  "${CODE_SERVER_USER_DATA_DIR}/User" \
  "${CODE_SERVER_PRIVATE_HOME}/.config" \
  "${CODE_SERVER_PRIVATE_HOME}/.cache" \
  "${CODE_SERVER_PRIVATE_HOME}/.local/share"
mkdir -p -- "$CODE_SERVER_EXTENSIONS_DIR"

[[ -r "$CODE_SERVER_SETTINGS_TEMPLATE" ]] \
  || die "Missing safe settings template: ${CODE_SERVER_SETTINGS_TEMPLATE}"
if [[ ! -e "${CODE_SERVER_USER_DATA_DIR}/User/settings.json" ]]; then
  install -m 0600 "$CODE_SERVER_SETTINGS_TEMPLATE" \
    "${CODE_SERVER_USER_DATA_DIR}/User/settings.json"
fi
chmod 0600 "${CODE_SERVER_USER_DATA_DIR}/User/settings.json"

# Do not export PASSWORD: extension hosts and integrated terminals inherit the
# server environment. A root-only ephemeral YAML config keeps the password out
# of both /workspace and Cline's processes.
CODE_SERVER_PASSWORD_FOR_CONFIG="$CODE_SERVER_PASSWORD" \
CODE_SERVER_BIND_FOR_CONFIG="127.0.0.1:${CODE_SERVER_PORT}" \
python3 - "$CODE_SERVER_CONFIG_FILE" <<'PY'
import json
import os
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
password = os.environ["CODE_SERVER_PASSWORD_FOR_CONFIG"]
bind_address = os.environ["CODE_SERVER_BIND_FOR_CONFIG"]
payload = (
    f"bind-addr: {json.dumps(bind_address)}\n"
    "auth: password\n"
    f"password: {json.dumps(password)}\n"
    "cert: false\n"
)
flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(target, flags, 0o600)
try:
    os.write(descriptor, payload.encode("utf-8"))
    os.fsync(descriptor)
finally:
    os.close(descriptor)
os.chmod(target, 0o600)
PY
unset CODE_SERVER_PASSWORD CODE_SERVER_PASSWORD_FOR_CONFIG

log "Starting code-server on private loopback 127.0.0.1:${CODE_SERVER_PORT}"
exec env -i \
  HOME="$CODE_SERVER_PRIVATE_HOME" \
  XDG_CONFIG_HOME="${CODE_SERVER_PRIVATE_HOME}/.config" \
  XDG_CACHE_HOME="${CODE_SERVER_PRIVATE_HOME}/.cache" \
  XDG_DATA_HOME="${CODE_SERVER_PRIVATE_HOME}/.local/share" \
  PATH=/usr/local/bin:/usr/bin:/bin \
  LANG=C.UTF-8 \
  SHELL=/bin/bash \
  "$CODE_SERVER_BIN" \
  --config "$CODE_SERVER_CONFIG_FILE" \
  --disable-telemetry \
  --disable-proxy \
  --user-data-dir "$CODE_SERVER_USER_DATA_DIR" \
  --extensions-dir "$CODE_SERVER_EXTENSIONS_DIR" \
  "$CODE_WORKSPACE"
