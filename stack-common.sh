#!/usr/bin/env bash

set -Eeuo pipefail

STACK_COMMON_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
STACK_ROOT="${AI_PHONE_STACK_ROOT:-$(cd -- "$(dirname -- "${STACK_COMMON_PATH}")" && pwd -P)}"
AI_PHONE_SECRET_DIR="${AI_PHONE_SECRET_DIR:-/run/secrets/ai-phone-stack}"
STACK_PRIVATE_RUN_DIR="${STACK_PRIVATE_RUN_DIR:-/run/ai-phone-stack/stack}"
STACK_LOG_DIR="${STACK_LOG_DIR:-/workspace/logs}"
STACK_LOCK_DIR="${STACK_PRIVATE_RUN_DIR}/lifecycle.lock"
STACK_LOCK_OWNER=0

SEARXNG_STACK_PID_FILE="${SEARXNG_STACK_PID_FILE:-${STACK_PRIVATE_RUN_DIR}/searxng.pid}"
SEARXNG_STACK_LOG_FILE="${SEARXNG_STACK_LOG_FILE:-${STACK_LOG_DIR}/searxng.log}"
SEARXNG_PORT="${SEARXNG_PORT:-8889}"
SEARXNG_HEALTH_URL="${SEARXNG_HEALTH_URL:-http://127.0.0.1:${SEARXNG_PORT}/}"

CODE_SERVER_STACK_PID_FILE="${CODE_SERVER_STACK_PID_FILE:-${STACK_PRIVATE_RUN_DIR}/code-server.pid}"
CODE_SERVER_STACK_LOG_FILE="${CODE_SERVER_STACK_LOG_FILE:-${STACK_LOG_DIR}/code-server.log}"
CODE_SERVER_PORT="${CODE_SERVER_PORT:-8443}"
CODE_SERVER_HEALTH_URL="${CODE_SERVER_HEALTH_URL:-http://127.0.0.1:${CODE_SERVER_PORT}/healthz}"

TAILSCALE_PRIVATE_RUN_DIR="${TAILSCALE_PRIVATE_RUN_DIR:-/run/ai-phone-stack/tailscale}"
TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-${TAILSCALE_PRIVATE_RUN_DIR}/tailscaled.sock}"
TAILSCALE_PID_FILE="${TAILSCALE_PID_FILE:-${TAILSCALE_PRIVATE_RUN_DIR}/tailscaled.pid}"

stack_log() {
  printf '[stack] %s\n' "$*" >&2
}

stack_warn() {
  printf '[stack] WARNING: %s\n' "$*" >&2
}

stack_die() {
  printf '[stack] ERROR: %s\n' "$*" >&2
  return 1
}

stack_require_command() {
  command -v "$1" >/dev/null 2>&1 || stack_die "commande requise introuvable: $1"
}

stack_prepare_private_dirs() {
  umask 077
  install -d -m 0700 "${STACK_PRIVATE_RUN_DIR}"
  mkdir -p -- "${STACK_LOG_DIR}"
}

stack_pid_from_file() {
  local pid_file="$1" process_id=""
  [[ -r "${pid_file}" ]] || return 1
  read -r process_id < "${pid_file}" || return 1
  [[ "${process_id}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "${process_id}"
}

stack_pid_matches() {
  local process_id="$1" marker="$2"
  kill -0 "${process_id}" 2>/dev/null || return 1
  if [[ -r "/proc/${process_id}/cmdline" ]]; then
    tr '\0' ' ' < "/proc/${process_id}/cmdline" | grep -F -- "${marker}" >/dev/null
  else
    ps -p "${process_id}" -o command= 2>/dev/null | grep -F -- "${marker}" >/dev/null
  fi
}

stack_managed_pid() {
  local pid_file="$1" marker="$2" process_id
  process_id="$(stack_pid_from_file "${pid_file}")" || return 1
  stack_pid_matches "${process_id}" "${marker}" || return 1
  printf '%s\n' "${process_id}"
}

stack_http_ok() {
  curl --fail --silent --show-error --max-time "${2:-5}" "$1" >/dev/null 2>&1
}

stack_wait_http() {
  local url="$1" timeout="$2" process_id="$3"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    kill -0 "${process_id}" 2>/dev/null || return 1
    stack_http_ok "${url}" 5 && return 0
    sleep 1
  done
  return 1
}

stack_start_managed_exec() {
  local name="$1" pid_file="$2" log_file="$3" marker="$4" health_url="$5" timeout="$6"
  shift 6
  local process_id pid_temp

  if process_id="$(stack_pid_from_file "${pid_file}" 2>/dev/null)"; then
    if kill -0 "${process_id}" 2>/dev/null; then
      stack_pid_matches "${process_id}" "${marker}" || stack_die \
        "${name}: le PID ${process_id} appartient à un autre processus; refus de le remplacer"
      stack_http_ok "${health_url}" 10 || stack_die \
        "${name}: processus géré actif mais endpoint non sain (${health_url})"
      stack_log "${name} déjà actif (PID ${process_id})"
      return 0
    fi
    rm -f -- "${pid_file}"
  elif [[ -e "${pid_file}" ]]; then
    stack_warn "${name}: suppression d'un pidfile invalide"
    rm -f -- "${pid_file}"
  fi

  stack_http_ok "${health_url}" 3 && stack_die \
    "${name}: un service non géré répond déjà sur ${health_url}"

  mkdir -p -- "$(dirname -- "${log_file}")"
  touch "${log_file}"
  chmod 0640 "${log_file}" 2>/dev/null || true
  stack_log "démarrage de ${name}"
  nohup "$@" >>"${log_file}" 2>&1 </dev/null &
  process_id=$!
  pid_temp="${pid_file}.$$"
  printf '%s\n' "${process_id}" > "${pid_temp}"
  mv -f -- "${pid_temp}" "${pid_file}"

  if ! stack_wait_http "${health_url}" "${timeout}" "${process_id}"; then
    tail -n 80 "${log_file}" >&2 || true
    if stack_pid_matches "${process_id}" "${marker}"; then
      kill -TERM "${process_id}" 2>/dev/null || true
    fi
    rm -f -- "${pid_file}"
    stack_die "${name}: échec du démarrage"
  fi
  stack_pid_matches "${process_id}" "${marker}" || stack_die \
    "${name}: endpoint sain mais processus inattendu"
  stack_log "${name} prêt (PID ${process_id})"
}

stack_stop_managed_exec() {
  local name="$1" pid_file="$2" marker="$3" timeout="${4:-30}"
  local process_id deadline
  if ! process_id="$(stack_pid_from_file "${pid_file}" 2>/dev/null)"; then
    [[ ! -e "${pid_file}" ]] || rm -f -- "${pid_file}"
    stack_log "${name} déjà arrêté"
    return 0
  fi
  if ! kill -0 "${process_id}" 2>/dev/null; then
    rm -f -- "${pid_file}"
    stack_log "${name}: pidfile périmé supprimé"
    return 0
  fi
  stack_pid_matches "${process_id}" "${marker}" || {
    stack_warn "${name}: PID ${process_id} étranger; aucun signal envoyé"
    return 1
  }

  stack_log "arrêt de ${name} (PID ${process_id})"
  kill -TERM "${process_id}"
  deadline=$((SECONDS + timeout))
  while kill -0 "${process_id}" 2>/dev/null && (( SECONDS < deadline )); do
    sleep 1
  done
  if kill -0 "${process_id}" 2>/dev/null; then
    if stack_pid_matches "${process_id}" "${marker}"; then
      stack_warn "${name}: arrêt forcé après ${timeout}s"
      kill -KILL "${process_id}"
    else
      stack_warn "${name}: PID réutilisé; aucun SIGKILL envoyé"
      return 1
    fi
  fi
  rm -f -- "${pid_file}"
}

stack_require_private_secret() {
  local name="$1" path="${AI_PHONE_SECRET_DIR}/$1" mode
  [[ -s "${path}" && -r "${path}" ]] || stack_die "secret d'exécution absent: ${name}"
  mode="$(stat -c '%a' "${path}" 2>/dev/null || true)"
  [[ "${mode}" =~ ^[0-7]+$ ]] || stack_die "permissions invérifiables: ${path}"
  (( ((8#${mode}) & 8#077) == 0 )) || stack_die \
    "secret trop ouvert (${mode}): ${path}"
}

stack_acquire_lock() {
  [[ "${STACK_LOCK_HELD:-0}" != "1" ]] || return 0
  stack_prepare_private_dirs
  local deadline=$((SECONDS + ${STACK_LOCK_TIMEOUT:-30}))
  local owner_pid="" owner_host="" current_host
  current_host="$(hostname)"
  while ! mkdir "${STACK_LOCK_DIR}" 2>/dev/null; do
    if [[ -r "${STACK_LOCK_DIR}/owner" ]]; then
      read -r owner_pid owner_host < "${STACK_LOCK_DIR}/owner" || true
    fi
    if [[ "${owner_host}" == "${current_host}" && "${owner_pid}" =~ ^[1-9][0-9]*$ ]] \
      && ! kill -0 "${owner_pid}" 2>/dev/null; then
      rm -f -- "${STACK_LOCK_DIR}/owner"
      rmdir "${STACK_LOCK_DIR}" 2>/dev/null || true
      continue
    fi
    (( SECONDS < deadline )) || stack_die "une autre opération start/stop est active"
    sleep 1
  done
  printf '%s %s\n' "$$" "${current_host}" > "${STACK_LOCK_DIR}/owner"
  STACK_LOCK_OWNER=1
  export STACK_LOCK_HELD=1
}

stack_release_lock() {
  (( STACK_LOCK_OWNER == 1 )) || return 0
  rm -f -- "${STACK_LOCK_DIR}/owner"
  rmdir "${STACK_LOCK_DIR}" 2>/dev/null || true
  STACK_LOCK_OWNER=0
}

