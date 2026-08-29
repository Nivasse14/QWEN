#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_command curl
require_command python3

service_pid="$(llama_pid)" || die "llama-server non actif ou PID non géré"
curl --fail --silent --show-error --max-time 10 "${LLAMA_BASE_URL}/health" >/dev/null

response_file="$(mktemp "${TMPDIR:-/tmp}/llama-models.XXXXXX")"
props_file="$(mktemp "${TMPDIR:-/tmp}/llama-props.XXXXXX")"
cleanup() {
  rm -f "$response_file" "$props_file"
  unset api_key
}
trap cleanup EXIT

curl_args=(--fail --silent --show-error --max-time 15)
if api_key="$(first_api_key 2>/dev/null)" && [[ -n "$api_key" ]]; then
  curl_args+=(--header "Authorization: Bearer ${api_key}")
fi
curl "${curl_args[@]}" "${LLAMA_BASE_URL}/v1/models" >"$response_file"
curl "${curl_args[@]}" "${LLAMA_BASE_URL}/props" >"$props_file"

expected_context="$(resolve_llama_context_size)"
python3 - "$response_file" "$props_file" "$LLAMA_ALIAS" "$service_pid" "$expected_context" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
props = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
expected = sys.argv[3]
ids = [item.get("id") for item in payload.get("data", [])]
if expected not in ids:
    raise SystemExit(f"alias absent de /v1/models: attendu={expected!r}, reçus={ids!r}")
actual_context = (props.get("default_generation_settings") or {}).get("n_ctx")
expected_context = int(sys.argv[5])
if actual_context != expected_context:
    raise SystemExit(
        f"contexte actif incorrect: attendu={expected_context}, reçu={actual_context!r}; redémarrer llama-server"
    )
print(
    json.dumps(
        {
            "status": "ok",
            "model": expected,
            "pid": int(sys.argv[4]),
            "context_size": actual_context,
        },
        ensure_ascii=False,
    )
)
PY
