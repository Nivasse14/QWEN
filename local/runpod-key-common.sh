#!/usr/bin/env bash

# Shared by local lifecycle scripts. This file never prints a key value.

runpod_key_error() {
  printf '[runpod-key] ERROR: %s\n' "$*" >&2
  return 1
}

runpod_key_file_path() {
  local config_base
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    config_base="${XDG_CONFIG_HOME}"
  else
    if [[ -z "${HOME:-}" ]]; then
      runpod_key_error "HOME is unset and XDG_CONFIG_HOME is not configured"
      return 1
    fi
    config_base="${HOME}/.config"
  fi
  if [[ "${config_base}" != /* ]]; then
    runpod_key_error "XDG_CONFIG_HOME must be an absolute path"
    return 1
  fi
  case "${config_base}" in
    /workspace|/workspace/*)
      runpod_key_error "refusing to store or read a RunPod key under /workspace"
      return 1
      ;;
  esac
  printf '%s/ai-phone-stack/runpod_api_key\n' "${config_base%/}"
}

runpod_file_mode() {
  local path="$1" mode
  mode="$(stat -c '%a' "${path}" 2>/dev/null || true)"
  if [[ ! "${mode}" =~ ^[0-7]+$ ]]; then
    mode="$(stat -f '%Lp' "${path}" 2>/dev/null || true)"
  fi
  [[ "${mode}" =~ ^[0-7]+$ ]] || return 1
  printf '%s\n' "${mode}"
}

runpod_key_value_valid() {
  local value="$1"
  [[ ${#value} -ge 20 && "${value}" != *[![:graph:]]* ]]
}

load_runpod_api_key() {
  local key_path key_mode key_value="" extra_line=""

  # An explicitly inherited environment variable takes precedence. It is
  # validated but never printed.
  if [[ "${RUNPOD_API_KEY+x}" == "x" ]]; then
    if ! runpod_key_value_valid "${RUNPOD_API_KEY}"; then
      runpod_key_error "RUNPOD_API_KEY is present but empty or malformed"
      return 1
    fi
    export RUNPOD_API_KEY
    return 0
  fi

  key_path="$(runpod_key_file_path)" || return 1
  [[ -e "${key_path}" || -L "${key_path}" ]] || return 0
  if [[ ! -f "${key_path}" || -L "${key_path}" || ! -r "${key_path}" ]]; then
    runpod_key_error "key path must be a readable regular file, not a symlink: ${key_path}"
    return 1
  fi
  if ! key_mode="$(runpod_file_mode "${key_path}")"; then
    runpod_key_error "cannot verify key permissions: ${key_path}"
    return 1
  fi
  if [[ "${key_mode}" != "600" ]]; then
    runpod_key_error "key file must have mode 600, found ${key_mode}: ${key_path}"
    return 1
  fi

  {
    IFS= read -r key_value || [[ -n "${key_value}" ]]
    if IFS= read -r extra_line; then
      runpod_key_error "key file must contain exactly one line"
      return 1
    fi
  } < "${key_path}"
  if ! runpod_key_value_valid "${key_value}"; then
    runpod_key_error "stored RunPod key is empty or malformed"
    return 1
  fi
  RUNPOD_API_KEY="${key_value}"
  export RUNPOD_API_KEY
  unset key_value extra_line
}
