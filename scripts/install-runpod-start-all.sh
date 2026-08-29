#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd -- "$(dirname -- "${SCRIPT_PATH}")/.." && pwd -P)"
ENTRYPOINT="${RUNPOD_STACK_ENTRYPOINT:-${STACK_ROOT}/runpod-entrypoint.sh}"
TARGET="${RUNPOD_START_ALL_PATH:-/workspace/start-all}"
DRY_RUN=0
[[ "${1:-}" != "--dry-run" ]] || DRY_RUN=1
[[ $# -le 1 ]] || { printf 'Usage: %s [--dry-run]\n' "$0" >&2; exit 2; }

[[ "${ENTRYPOINT}" == /* && -x "${ENTRYPOINT}" ]] || {
  printf '[install-start-all] entrypoint absent ou non exécutable: %s\n' "${ENTRYPOINT}" >&2
  exit 1
}
[[ "${TARGET}" == /workspace/* ]] || {
  printf '[install-start-all] cible refusée hors de /workspace: %s\n' "${TARGET}" >&2
  exit 1
}

if [[ -L "${TARGET}" ]] && [[ "$(readlink -f -- "${TARGET}" 2>/dev/null || true)" == "${ENTRYPOINT}" ]]; then
  printf '[install-start-all] lien déjà correct: %s\n' "${TARGET}"
  exit 0
fi

backup=""
if [[ -e "${TARGET}" || -L "${TARGET}" ]]; then
  backup="${TARGET}.backup.$(date -u +%Y%m%dT%H%M%SZ).$$"
fi

if (( DRY_RUN == 1 )); then
  [[ -z "${backup}" ]] || printf '[install-start-all] sauvegarderait %s vers %s\n' "${TARGET}" "${backup}"
  printf '[install-start-all] créerait %s -> %s\n' "${TARGET}" "${ENTRYPOINT}"
  exit 0
fi

temporary="$(dirname -- "${TARGET}")/.start-all.new.$$"
rollback_files() {
  set +e
  rm -f -- "${temporary}"
  if [[ -n "${backup}" && ! -e "${TARGET}" && ! -L "${TARGET}" \
    && ( -e "${backup}" || -L "${backup}" ) ]]; then
    mv -- "${backup}" "${TARGET}" || true
  fi
}
on_error() {
  local exit_code=$?
  trap - ERR
  rollback_files
  exit "${exit_code}"
}
on_signal() {
  local exit_code="$1"
  trap - ERR INT TERM
  rollback_files
  exit "${exit_code}"
}
trap on_error ERR
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

[[ -z "${backup}" ]] || mv -- "${TARGET}" "${backup}"
ln -s -- "${ENTRYPOINT}" "${temporary}"
mv -T -- "${temporary}" "${TARGET}"
[[ "$(readlink -f -- "${TARGET}")" == "${ENTRYPOINT}" ]]
trap - ERR INT TERM

printf '[install-start-all] installé: %s -> %s\n' "${TARGET}" "${ENTRYPOINT}"
[[ -z "${backup}" ]] || printf '[install-start-all] ancien lanceur conservé: %s\n' "${backup}"
