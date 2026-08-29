#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${STACK_ROOT}/.local-state"
POD_ID_FILE="${STATE_DIR}/current-pod-id"
STORAGE_MODE_FILE="${STATE_DIR}/current-storage-mode"
ENV_FILE="${AI_PHONE_LOCAL_ENV_FILE:-${STACK_ROOT}/.env.local}"

if [[ "${SCRIPT_DIR}" == /workspace/* ]]; then
  printf '[runpod-stop] ERROR: ce script doit être exécuté depuis un poste local de confiance, jamais depuis le Pod.\n' >&2
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
TERMINATE_REDEPLOY=0
DRY_RUN=0
CONFIRM_POD_ID=""
usage() {
  printf 'Usage: %s [--dry-run] [--terminate-redeploy --confirm-pod-id POD_ID]\n' "$0"
}
while (( $# > 0 )); do
  case "$1" in
    --terminate-redeploy)
      TERMINATE_REDEPLOY=1
      shift
      ;;
    --confirm-pod-id)
      (( $# >= 2 )) || { usage >&2; exit 2; }
      CONFIRM_POD_ID="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '[runpod-stop] ERROR: Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

die() { printf '[runpod-stop] ERROR: %s\n' "$*" >&2; exit 1; }
command -v "${RUNPODCTL_BIN}" >/dev/null 2>&1 || die "runpodctl is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
pod_id=""
if [[ -r "${POD_ID_FILE}" ]]; then
  pod_id="$(tr -d '\r\n' < "${POD_ID_FILE}")"
else
  pod_id="${RUNPOD_POD_ID:-}"
fi
[[ -n "${pod_id}" ]] || die "No Pod id found; set RUNPOD_POD_ID or run start-pod.sh first"
storage_mode="${RUNPOD_STORAGE_MODE:-}"
if [[ -z "${storage_mode}" && -r "${STORAGE_MODE_FILE}" ]]; then
  storage_mode="$(tr -d '\r\n' < "${STORAGE_MODE_FILE}")"
fi
storage_mode="${storage_mode:-network-volume}"

if [[ "${storage_mode}" == "network-volume" ]]; then
  if [[ "${TERMINATE_REDEPLOY}" != "1" ]]; then
    die "A Secure Cloud Pod attached to a network volume is handled as terminate/redeploy, not stop/start. Use --dry-run first, then --terminate-redeploy --confirm-pod-id ${pod_id}; the network volume survives, but the container disk does not."
  fi
  expected_volume_id="${RUNPOD_NETWORK_VOLUME_ID:-}"
  [[ -n "${expected_volume_id}" ]] || die \
    "RUNPOD_NETWORK_VOLUME_ID is required to verify the persistent volume before deletion"
  if [[ -n "${CONFIRM_POD_ID}" && "${CONFIRM_POD_ID}" != "${pod_id}" ]]; then
    die "confirmation mismatch: expected exact Pod id ${pod_id}, got ${CONFIRM_POD_ID}"
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[runpod-stop] DRY RUN: would verify Pod %s is attached to network volume %s.\n' \
      "${pod_id}" "${expected_volume_id}"
    printf '%q ' "${RUNPODCTL_BIN}" pod delete "${pod_id}"
    printf '\n'
    printf '[runpod-stop] To execute: %q --terminate-redeploy --confirm-pod-id %q\n' \
      "$0" "${pod_id}"
    exit 0
  fi
  [[ "${CONFIRM_POD_ID}" == "${pod_id}" ]] || die \
    "explicit confirmation required: --confirm-pod-id ${pod_id}"

  umask 077
  pod_details_file="$(mktemp)"
  cleanup() { rm -f -- "${pod_details_file}"; }
  trap cleanup EXIT
  "${RUNPODCTL_BIN}" pod get "${pod_id}" --include-network-volume --output json \
    > "${pod_details_file}"
  python3 - "${pod_details_file}" "${pod_id}" "${expected_volume_id}" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected_pod, expected_volume = sys.argv[2], sys.argv[3]
if isinstance(payload, list):
    if len(payload) != 1:
        raise SystemExit("unexpected Pod lookup result")
    payload = payload[0]
if not isinstance(payload, dict):
    raise SystemExit("unexpected Pod lookup payload")
actual_pod = payload.get("id") or payload.get("podId")
if actual_pod != expected_pod:
    raise SystemExit(f"Pod identity mismatch: expected {expected_pod}, got {actual_pod}")

volume_ids = set()
for key in ("networkVolumeId", "network_volume_id"):
    value = payload.get(key)
    if isinstance(value, str):
        volume_ids.add(value)
network_volume = payload.get("networkVolume") or payload.get("network_volume")
if isinstance(network_volume, dict):
    for key in ("id", "networkVolumeId", "network_volume_id"):
        value = network_volume.get(key)
        if isinstance(value, str):
            volume_ids.add(value)
elif isinstance(network_volume, str):
    volume_ids.add(network_volume)

if expected_volume not in volume_ids:
    found = ", ".join(sorted(volume_ids)) or "none reported"
    raise SystemExit(
        f"network volume mismatch: expected {expected_volume}, found {found}; deletion refused"
    )
PY
  printf '[runpod-stop] Verified Pod %s and network volume %s.\n' \
    "${pod_id}" "${expected_volume_id}"
  printf '[runpod-stop] Terminating Pod %s; persistent data stays on the network volume.\n' "${pod_id}"
  "${RUNPODCTL_BIN}" pod delete "${pod_id}"
  rm -f -- "${POD_ID_FILE}" "${STORAGE_MODE_FILE}"
  printf '[runpod-stop] Next start-pod.sh run will deploy a new Pod on the same volume.\n'
else
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '%q ' "${RUNPODCTL_BIN}" pod stop "${pod_id}"
    printf '\n'
    exit 0
  fi
  printf '[runpod-stop] Stopping Pod-volume Pod %s. Its /workspace Pod volume is retained.\n' "${pod_id}"
  "${RUNPODCTL_BIN}" pod stop "${pod_id}"
fi
