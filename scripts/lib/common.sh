#!/usr/bin/env bash

set -Eeuo pipefail

COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_STACK_ROOT="$(cd -- "${COMMON_DIR}/../.." && pwd)"
STACK_ROOT="${AI_PHONE_STACK_ROOT:-${DEFAULT_STACK_ROOT}}"
RUNTIME_DIR="${AI_PHONE_RUNTIME_DIR:-${STACK_ROOT}/.runtime}"
STATE_DIR="${AI_PHONE_STATE_DIR:-${STACK_ROOT}/state}"
RUN_DIR="${AI_PHONE_RUN_DIR:-${STACK_ROOT}/run}"
VENDOR_DIR="${AI_PHONE_VENDOR_DIR:-${STACK_ROOT}/vendor}"

log() {
  printf '[ai-phone-stack] %s\n' "$*"
}

warn() {
  printf '[ai-phone-stack] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[ai-phone-stack] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ensure_stack_dirs() {
  mkdir -p -- "${RUNTIME_DIR}" "${STATE_DIR}" "${RUN_DIR}" "${VENDOR_DIR}"
}

pid_is_running() {
  local pid_file="$1"
  [[ -f "${pid_file}" ]] || return 1
  local process_id
  process_id="$(tr -dc '0-9' < "${pid_file}")"
  [[ -n "${process_id}" ]] || return 1
  kill -0 "${process_id}" 2>/dev/null
}

read_secret_file() {
  local secret_file="$1"
  [[ -r "${secret_file}" ]] || die "Secret file is not readable: ${secret_file}"
  local secret_mode
  secret_mode="$(stat -c '%a' "${secret_file}" 2>/dev/null || true)"
  [[ "${secret_mode}" =~ ^[0-7]+$ ]] || die \
    "Cannot verify permissions on secret file: ${secret_file}"
  if (( (8#${secret_mode}) & 8#077 )); then
    die "Secret file ${secret_file} is accessible by group/others (mode ${secret_mode}); use an injected environment variable instead"
  fi
  tr -d '\r\n' < "${secret_file}"
}
