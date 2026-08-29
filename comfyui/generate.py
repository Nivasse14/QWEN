#!/usr/bin/env python3
"""Submit the fixed FLUX 720p workflow to ComfyUI and download its PNG."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import secrets
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
DEFAULT_WORKFLOW = SCRIPT_DIR / "workflows" / "img720.json"


class GenerationError(RuntimeError):
    """Raised when ComfyUI rejects or fails a generation."""


def request_json(
    base_url: str,
    path: str,
    *,
    payload: dict[str, Any] | None = None,
    timeout: float = 30,
) -> dict[str, Any]:
    data = None
    headers = {"Accept": "application/json"}
    method = "GET"
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
        method = "POST"
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}{path}", data=data, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, json.JSONDecodeError) as exc:
        raise GenerationError(f"requête ComfyUI échouée ({path}): {exc}") from exc


def load_workflow(path: pathlib.Path, prompt: str, seed: int, prefix: str) -> dict[str, Any]:
    workflow = json.loads(path.read_text(encoding="utf-8"))
    workflow["4"]["inputs"]["text"] = prompt
    workflow["8"]["inputs"]["seed"] = seed
    workflow["10"]["inputs"]["filename_prefix"] = prefix

    workflow["1"]["inputs"]["unet_name"] = os.getenv(
        "FLUX_UNET_FILENAME", "flux1-dev-Q5_K_S.gguf"
    )
    workflow["2"]["inputs"]["clip_name1"] = os.getenv(
        "FLUX_CLIP_FILENAME", "clip_l.safetensors"
    )
    workflow["2"]["inputs"]["clip_name2"] = os.getenv(
        "FLUX_T5_FILENAME", "t5-v1_1-xxl-encoder-Q4_K_M.gguf"
    )
    workflow["3"]["inputs"]["vae_name"] = os.getenv(
        "FLUX_VAE_FILENAME", "ae.safetensors"
    )
    return workflow


def find_image(history_entry: dict[str, Any]) -> dict[str, str] | None:
    for output in history_entry.get("outputs", {}).values():
        images = output.get("images", [])
        if images:
            image = images[0]
            return {
                "filename": str(image["filename"]),
                "subfolder": str(image.get("subfolder", "")),
                "type": str(image.get("type", "output")),
            }
    return None


def assert_not_failed(history_entry: dict[str, Any]) -> None:
    status = history_entry.get("status", {})
    if status.get("status_str") == "error":
        raise GenerationError(f"exécution ComfyUI en erreur: {status}")
    for message in status.get("messages", []):
        if message and message[0] in {"execution_error", "execution_interrupted"}:
            raise GenerationError(f"exécution ComfyUI interrompue: {message}")


def wait_for_image(base_url: str, prompt_id: str, timeout: int) -> dict[str, str]:
    deadline = time.monotonic() + timeout
    quoted_id = urllib.parse.quote(prompt_id, safe="")
    while time.monotonic() < deadline:
        history = request_json(base_url, f"/history/{quoted_id}", timeout=30)
        entry = history.get(prompt_id)
        if entry:
            assert_not_failed(entry)
            image = find_image(entry)
            if image:
                return image
        time.sleep(2)
    raise GenerationError(f"délai de génération dépassé après {timeout}s")


def download_image(base_url: str, image: dict[str, str], timeout: int) -> bytes:
    query = urllib.parse.urlencode(image)
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/view?{query}", headers={"Accept": "image/png"}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.URLError as exc:
        raise GenerationError(f"téléchargement PNG échoué: {exc}") from exc


def png_dimensions(data: bytes) -> tuple[int, int]:
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise GenerationError("la réponse n'est pas un PNG valide")
    return struct.unpack(">II", data[16:24])


def atomic_write(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        temporary.write_bytes(data)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prompt", help="prompt texte envoyé à FLUX")
    parser.add_argument(
        "--base-url", default=os.getenv("COMFYUI_URL", "http://127.0.0.1:8188")
    )
    parser.add_argument("--workflow", type=pathlib.Path, default=DEFAULT_WORKFLOW)
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("img720.png"))
    parser.add_argument("--prefix", default="img720")
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--timeout", type=int, default=1800)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    seed = args.seed if args.seed is not None else secrets.randbelow(2**63)
    workflow = load_workflow(args.workflow, args.prompt, seed, args.prefix)
    queued = request_json(
        args.base_url,
        "/prompt",
        payload={"prompt": workflow, "client_id": uuid.uuid4().hex},
        timeout=30,
    )
    prompt_id = queued.get("prompt_id")
    if not isinstance(prompt_id, str) or not prompt_id:
        raise GenerationError(f"ComfyUI n'a pas renvoyé de prompt_id: {queued}")

    image_info = wait_for_image(args.base_url, prompt_id, args.timeout)
    png = download_image(args.base_url, image_info, min(args.timeout, 120))
    width, height = png_dimensions(png)
    if (width, height) != (1280, 720):
        raise GenerationError(f"dimensions inattendues: {width}x{height}, attendu 1280x720")
    atomic_write(args.output, png)
    print(
        json.dumps(
            {
                "status": "ok",
                "prompt_id": prompt_id,
                "seed": seed,
                "width": width,
                "height": height,
                "file": str(args.output.resolve()),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GenerationError, OSError, ValueError) as exc:
        print(json.dumps({"status": "error", "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1) from exc
