#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_command curl
require_command python3
service_pid="$(comfyui_pid)" || die "ComfyUI non actif ou PID non géré"

stats_file="$(mktemp "${TMPDIR:-/tmp}/comfy-stats.XXXXXX")"
nodes_file="$(mktemp "${TMPDIR:-/tmp}/comfy-nodes.XXXXXX")"
cleanup() { rm -f "$stats_file" "$nodes_file"; }
trap cleanup EXIT
curl --fail --silent --show-error --max-time 15 "${COMFYUI_URL}/system_stats" >"$stats_file"
curl --fail --silent --show-error --max-time 30 "${COMFYUI_URL}/object_info" >"$nodes_file"

python3 - "$stats_file" "$nodes_file" "$service_pid" <<'PY'
import json
import pathlib
import sys

json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
nodes = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
required = {"UnetLoaderGGUF", "DualCLIPLoaderGGUF", "FluxGuidance", "EmptySD3LatentImage", "KSampler"}
missing = sorted(required.difference(nodes))
if missing:
    raise SystemExit(f"nœuds ComfyUI absents: {missing}")
print(json.dumps({"status": "ok", "pid": int(sys.argv[3])}, ensure_ascii=False))
PY
