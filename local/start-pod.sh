#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${STACK_ROOT}/.local-state"
POD_ID_FILE="${STATE_DIR}/current-pod-id"
STORAGE_MODE_FILE="${STATE_DIR}/current-storage-mode"
ENV_FILE="${AI_PHONE_LOCAL_ENV_FILE:-${STACK_ROOT}/.env.local}"

if [[ "${SCRIPT_DIR}" == /workspace/* ]]; then
  printf '[runpod-start] ERROR: ce script doit être exécuté depuis un poste local de confiance, jamais depuis le Pod.\n' >&2
  exit 1
fi

if [[ -r "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

# shellcheck source=runpod-key-common.sh
source "${SCRIPT_DIR}/runpod-key-common.sh"
load_runpod_api_key

RUNPODCTL_BIN="${RUNPODCTL_BIN:-runpodctl}"
RUNPOD_STORAGE_MODE="${RUNPOD_STORAGE_MODE:-network-volume}"
DRY_RUN=0
PREVIEW_REDEPLOY=0
usage() {
  printf 'Usage: %s [--dry-run | --preview-redeploy]\n' "$0"
}
while (( $# > 0 )); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --preview-redeploy)
      PREVIEW_REDEPLOY=1
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '[runpod-start] ERROR: Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() { printf '[runpod-start] %s\n' "$*"; }
die() { printf '[runpod-start] ERROR: %s\n' "$*" >&2; exit 1; }
require_value() { [[ -n "${!1:-}" ]] || die "Set $1 in ${ENV_FILE}"; }
require_configured_value() {
  require_value "$1"
  [[ "${!1}" != replace-with-* ]] || die "Replace the placeholder $1 in ${ENV_FILE}"
}
command -v "${RUNPODCTL_BIN}" >/dev/null 2>&1 || die "runpodctl is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[[ "${RUNPOD_STORAGE_MODE}" == "network-volume" || "${RUNPOD_STORAGE_MODE}" == "pod-volume" ]] || \
  die "RUNPOD_STORAGE_MODE must be network-volume or pod-volume"

mkdir -p -- "${STATE_DIR}"
pod_id=""
if [[ -r "${POD_ID_FILE}" ]]; then
  pod_id="$(tr -d '\r\n' < "${POD_ID_FILE}")"
else
  pod_id="${RUNPOD_POD_ID:-}"
fi

pod_runtime_status() {
  "${RUNPODCTL_BIN}" pod get "$1" --include-network-volume --output json 2>/dev/null | \
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("runtimeStatus") or d.get("desiredStatus") or "unknown")'
}

if [[ -n "${pod_id}" && "${PREVIEW_REDEPLOY}" != "1" ]]; then
  existing_status="$(pod_runtime_status "${pod_id}" || true)"
  case "${existing_status,,}" in
    running|initializing)
      log "Pod ${pod_id} is already ${existing_status,,}."
      if [[ "${DRY_RUN}" != "1" ]]; then
        printf '%s\n' "${pod_id}" > "${POD_ID_FILE}"
        printf '%s\n' "${RUNPOD_STORAGE_MODE}" > "${STORAGE_MODE_FILE}"
      fi
      "${RUNPODCTL_BIN}" pod get "${pod_id}" --include-machine --include-network-volume
      exit 0
      ;;
    stopped|exited)
      if [[ "${RUNPOD_STORAGE_MODE}" == "network-volume" ]]; then
        die "Network-volume Pod ${pod_id} is not running. Terminate it explicitly with local/stop-pod.sh --terminate-redeploy, then rerun this script."
      fi
      if [[ "${DRY_RUN}" == "1" ]]; then
        printf '%q ' "${RUNPODCTL_BIN}" pod start "${pod_id}"
        printf '\n'
      else
        log "Restarting Pod-volume Pod ${pod_id}"
        "${RUNPODCTL_BIN}" pod start "${pod_id}"
      fi
      exit 0
      ;;
    "")
      log "Stored Pod ${pod_id} no longer exists; creating a replacement"
      ;;
    *)
      die "Pod ${pod_id} has unsupported status '${existing_status}'. Inspect it with runpodctl pod get ${pod_id}."
      ;;
  esac
fi

require_configured_value RUNPOD_TEMPLATE_ID
require_value RUNPOD_GPU_ID
create_args=(pod create
  --template-id "${RUNPOD_TEMPLATE_ID}"
  --gpu-id "${RUNPOD_GPU_ID}"
  --gpu-count 1
  --name "${RUNPOD_POD_NAME:-ai-phone-stack}"
  --ssh
  --output json)

if [[ -n "${RUNPOD_PORTS:-}" ]]; then
  create_args+=(--ports "${RUNPOD_PORTS}")
fi
if [[ -n "${RUNPOD_DATA_CENTER_IDS:-}" ]]; then
  create_args+=(--data-center-ids "${RUNPOD_DATA_CENTER_IDS}")
fi

if [[ "${RUNPOD_STORAGE_MODE}" == "network-volume" ]]; then
  require_configured_value RUNPOD_NETWORK_VOLUME_ID
  create_args+=(--cloud-type SECURE --network-volume-id "${RUNPOD_NETWORK_VOLUME_ID}")
else
  create_args+=(
    --cloud-type "${RUNPOD_CLOUD_TYPE:-COMMUNITY}"
    --volume-in-gb "${RUNPOD_POD_VOLUME_GB:-300}"
    --volume-mount-path /workspace)
  [[ "${RUNPOD_PUBLIC_IP:-0}" == "1" ]] && create_args+=(--public-ip)
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  [[ "${PREVIEW_REDEPLOY}" != "1" ]] || log \
    "REDEPLOY PREVIEW: no Pod lookup or mutation will be performed"
  printf '%q ' "${RUNPODCTL_BIN}" "${create_args[@]}"
  printf '\n'
  exit 0
fi

log "Creating a ${RUNPOD_STORAGE_MODE} Pod"
output_file="$(mktemp)"
cleanup() { rm -f -- "${output_file}"; }
trap cleanup EXIT
"${RUNPODCTL_BIN}" "${create_args[@]}" | tee "${output_file}"
new_pod_id="$(python3 - "${output_file}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if isinstance(data, list) and data:
    data = data[0]
if not isinstance(data, dict):
    raise SystemExit("unexpected runpodctl output")
pod_id = data.get("id") or data.get("podId")
if not pod_id:
    raise SystemExit("pod id missing from runpodctl output")
print(pod_id)
PY
)"
printf '%s\n' "${new_pod_id}" > "${POD_ID_FILE}"
printf '%s\n' "${RUNPOD_STORAGE_MODE}" > "${STORAGE_MODE_FILE}"
log "Saved Pod id ${new_pod_id}. RunPod may still be initializing it."
