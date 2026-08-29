#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
COMFYUI_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

while IFS= read -r script; do
  bash -n "$script" || fail "syntaxe shell invalide: $script"
done < <(find "$COMFYUI_DIR" -maxdepth 2 -type f -name '*.sh' -print | sort)

python3 - "$COMFYUI_DIR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
workflow = json.loads((root / "workflows" / "img720.json").read_text(encoding="utf-8"))
by_type = {node["class_type"]: node for node in workflow.values()}

required = {
    "UnetLoaderGGUF",
    "DualCLIPLoaderGGUF",
    "VAELoader",
    "FluxGuidance",
    "EmptySD3LatentImage",
    "KSampler",
    "VAEDecode",
    "SaveImage",
}
missing = required.difference(by_type)
assert not missing, f"nœuds absents: {sorted(missing)}"
assert by_type["UnetLoaderGGUF"]["inputs"]["unet_name"] == "flux1-dev-Q5_K_S.gguf"
assert by_type["DualCLIPLoaderGGUF"]["inputs"]["clip_name1"] == "clip_l.safetensors"
assert by_type["DualCLIPLoaderGGUF"]["inputs"]["clip_name2"] == "t5-v1_1-xxl-encoder-Q4_K_M.gguf"
assert by_type["DualCLIPLoaderGGUF"]["inputs"]["type"] == "flux"
assert by_type["VAELoader"]["inputs"]["vae_name"] == "ae.safetensors"
assert by_type["FluxGuidance"]["inputs"]["guidance"] == 3.5
assert by_type["EmptySD3LatentImage"]["inputs"] == {
    "width": 1280,
    "height": 720,
    "batch_size": 1,
}
sampler = by_type["KSampler"]["inputs"]
assert sampler["steps"] == 20
assert sampler["cfg"] == 1.0
assert sampler["sampler_name"] == "euler"
assert sampler["scheduler"] == "simple"
compile((root / "generate.py").read_text(encoding="utf-8"), str(root / "generate.py"), "exec")
orchestrator_source = (root / "orchestrator.py").read_text(encoding="utf-8")
compile(orchestrator_source, str(root / "orchestrator.py"), "exec")
assert '"/v1/images/generations"' in orchestrator_source
assert '"127.0.0.1"' in orchestrator_source
assert '"8003"' in orchestrator_source
ordered = [
    'run_script(LLM_DIR / "stop.sh"',
    'run_script(SCRIPT_DIR / "start.sh"',
    'str(SCRIPT_DIR / "generate.py")',
    'run_script(SCRIPT_DIR / "stop.sh"',
    'run_script(LLM_DIR / "start.sh"',
]
positions = [orchestrator_source.index(value) for value in ordered]
assert positions == sorted(positions), positions
assert "with REQUEST_LOCK, gpu_lock()" in orchestrator_source
assert 'width = request.get("width", 1280)' in orchestrator_source
assert 'height = request.get("height", 720)' in orchestrator_source
assert 'not isinstance(request, dict)' in orchestrator_source
print("OK: workflow FLUX API 1280x720 et orchestrateur OpenAI mutex")
PY

grep -F 'city96/FLUX.1-dev-gguf' "${COMFYUI_DIR}/common.sh" >/dev/null \
  || fail "dépôt city96 FLUX absent"
grep -F 'https://github.com/Comfy-Org/ComfyUI.git' "${COMFYUI_DIR}/common.sh" >/dev/null \
  || fail "dépôt canonique ComfyUI absent"
grep -F 'black-forest-labs/FLUX.1-dev' "${COMFYUI_DIR}/common.sh" >/dev/null \
  || fail "VAE officiel FLUX absent"
grep -F 'COMFYUI_SOURCE_DIR="${COMFYUI_SOURCE_DIR:-/workspace/ComfyUI}"' "${COMFYUI_DIR}/common.sh" >/dev/null \
  || fail "source ComfyUI native absente"
grep -F 'COMFYUI_VENV_DIR="${COMFYUI_VENV_DIR:-/workspace/venvs/comfyui}"' "${COMFYUI_DIR}/common.sh" >/dev/null \
  || fail "venv ComfyUI natif absent"
grep -F 'nohup env PYTORCH_CUDA_ALLOC_CONF' "${COMFYUI_DIR}/start.sh" >/dev/null \
  || fail "démarrage natif ComfyUI absent"
grep -F '/run/secrets/ai-phone-stack/flux_orchestrator_token' "${COMFYUI_DIR}/common.sh" >/dev/null \
  || fail "clé orchestrateur hors /workspace absente"
grep -F 'FLUX_ORCHESTRATOR_BASE_URL="${FLUX_ORCHESTRATOR_BASE_URL:-http://127.0.0.1:${FLUX_ORCHESTRATOR_PORT}}"' "${COMFYUI_DIR}/common.sh" >/dev/null \
  || fail "URL de base orchestrateur absente"
grep -F 'FLUX_ORCHESTRATOR_URL="${FLUX_ORCHESTRATOR_URL:-${FLUX_ORCHESTRATOR_BASE_URL}/v1/images/generations}"' "${COMFYUI_DIR}/common.sh" >/dev/null \
  || fail "endpoint tools-api incomplet"
grep -F '"${FLUX_ORCHESTRATOR_BASE_URL}/health"' "${COMFYUI_DIR}/health-orchestrator.sh" >/dev/null \
  || fail "health orchestrateur ne doit pas utiliser l'endpoint de génération"

if find "$COMFYUI_DIR" -type f ! -path '*/tests/*' -print0 \
  | xargs -0 grep -i -F 'docker' >/dev/null 2>&1; then
  fail "ComfyUI natif ne doit dépendre d'aucun Docker"
fi

printf 'OK: scripts ComfyUI natifs, venv, modèles et API localhost:8003\n'
