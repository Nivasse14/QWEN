#!/usr/bin/env python3
"""Local OpenAI-compatible image API that safely alternates one GPU."""

from __future__ import annotations

import argparse
import base64
import contextlib
import hmac
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Iterator
from urllib.parse import urlparse


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
LLM_DIR = SCRIPT_DIR.parent / "llm"
RUNTIME_DIR = pathlib.Path(os.getenv("AI_STACK_RUNTIME_DIR", "/workspace/run/ai-phone-stack"))
GPU_LOCK_DIR = pathlib.Path(os.getenv("GPU_MUTEX_DIR", str(RUNTIME_DIR / "gpu-switch.lock")))
LOCK_TIMEOUT = int(os.getenv("GPU_MUTEX_TIMEOUT", "60"))
GENERATION_TIMEOUT = int(os.getenv("FLUX_GENERATION_TIMEOUT", "1800"))
SERVICE_TIMEOUT = int(os.getenv("FLUX_SERVICE_SWITCH_TIMEOUT", "720"))
OUTPUT_DIR = pathlib.Path(
    os.getenv("FLUX_ORCHESTRATOR_OUTPUT_DIR", "/workspace/ComfyUI/output/orchestrator")
)
PUBLIC_URL = os.getenv("FLUX_ORCHESTRATOR_PUBLIC_URL", "http://127.0.0.1:8003").rstrip("/")
KEY_FILE_VALUE = os.getenv(
    "FLUX_ORCHESTRATOR_API_KEY_FILE",
    "/run/secrets/ai-phone-stack/flux_orchestrator_token",
)
KEY_FILE = pathlib.Path(KEY_FILE_VALUE) if KEY_FILE_VALUE else None
REQUEST_LOCK = threading.Lock()


class OrchestrationError(RuntimeError):
    pass


def read_api_keys() -> list[str]:
    if KEY_FILE is None:
        return []
    if not str(KEY_FILE).startswith("/run/"):
        raise OrchestrationError("le fichier de clés doit être matérialisé sous /run")
    if not KEY_FILE.exists():
        return []
    keys = [
        line.strip().split()[0]
        for line in KEY_FILE.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not keys:
        raise OrchestrationError(f"fichier de clés vide: {KEY_FILE}")
    return keys


def authorized(header: str | None) -> bool:
    keys = read_api_keys()
    if not keys:
        return True
    if not header or not header.startswith("Bearer "):
        return False
    candidate = header.removeprefix("Bearer ").strip()
    return any(hmac.compare_digest(candidate, key) for key in keys)


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    try:
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
        state = stat.rsplit(") ", 1)[1].split(maxsplit=1)[0]
        if state in {"Z", "X"}:
            return False
    except (OSError, IndexError):
        pass
    return True


@contextlib.contextmanager
def gpu_lock() -> Iterator[None]:
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + LOCK_TIMEOUT
    hostname = socket.gethostname()
    while True:
        try:
            GPU_LOCK_DIR.mkdir(mode=0o750)
            break
        except FileExistsError:
            owner_file = GPU_LOCK_DIR / "owner"
            try:
                owner_pid_text, owner_host = owner_file.read_text(encoding="utf-8").split()[:2]
                owner_pid = int(owner_pid_text)
            except (OSError, ValueError, IndexError):
                owner_pid, owner_host = 0, ""
            if owner_host and owner_host != hostname:
                owner_file.unlink(missing_ok=True)
                with contextlib.suppress(OSError):
                    GPU_LOCK_DIR.rmdir()
                continue
            if owner_host == hostname and owner_pid and not process_alive(owner_pid):
                owner_file.unlink(missing_ok=True)
                with contextlib.suppress(OSError):
                    GPU_LOCK_DIR.rmdir()
                continue
            if not owner_pid:
                try:
                    lock_age = time.time() - GPU_LOCK_DIR.stat().st_mtime
                except OSError:
                    lock_age = 0
                if lock_age >= 5:
                    owner_file.unlink(missing_ok=True)
                    with contextlib.suppress(OSError):
                        GPU_LOCK_DIR.rmdir()
                    continue
            if time.monotonic() >= deadline:
                raise OrchestrationError(f"verrou GPU occupé depuis plus de {LOCK_TIMEOUT}s")
            time.sleep(1)

    owner_file = GPU_LOCK_DIR / "owner"
    owner_file.write_text(f"{os.getpid()} {hostname}\n", encoding="utf-8")
    try:
        yield
    finally:
        owner_file.unlink(missing_ok=True)
        with contextlib.suppress(OSError):
            GPU_LOCK_DIR.rmdir()


def run_script(path: pathlib.Path, *args: str, timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            [str(path), *args],
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=os.environ.copy(),
        )
    except subprocess.TimeoutExpired as exc:
        raise OrchestrationError(f"délai dépassé: {path.name}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()[-4000:]
        raise OrchestrationError(f"échec {path.name}: {detail}") from exc


def generate_png(prompt: str, seed: int | None) -> bytes:
    primary_error: Exception | None = None
    restore_errors: list[str] = []
    png = b""

    with REQUEST_LOCK, gpu_lock(), tempfile.TemporaryDirectory(prefix="flux-api-") as tmp:
        output = pathlib.Path(tmp) / "image.png"
        try:
            run_script(LLM_DIR / "stop.sh", timeout=SERVICE_TIMEOUT)
            run_script(SCRIPT_DIR / "start.sh", timeout=SERVICE_TIMEOUT)
            command_args = [
                prompt,
                "--base-url",
                os.getenv("COMFYUI_URL", "http://127.0.0.1:8188"),
                "--output",
                str(output),
                "--timeout",
                str(GENERATION_TIMEOUT),
            ]
            if seed is not None:
                command_args.extend(["--seed", str(seed)])
            run_script(
                pathlib.Path(sys.executable),
                str(SCRIPT_DIR / "generate.py"),
                *command_args,
                timeout=GENERATION_TIMEOUT + 60,
            )
            png = output.read_bytes()
        except Exception as exc:  # restoration must still run
            primary_error = exc
        finally:
            try:
                run_script(SCRIPT_DIR / "stop.sh", timeout=SERVICE_TIMEOUT)
            except Exception as exc:
                restore_errors.append(str(exc))
            try:
                run_script(LLM_DIR / "start.sh", timeout=SERVICE_TIMEOUT)
            except Exception as exc:
                restore_errors.append(str(exc))

    if primary_error is not None:
        suffix = f"; restauration: {'; '.join(restore_errors)}" if restore_errors else ""
        raise OrchestrationError(f"{primary_error}{suffix}") from primary_error
    if restore_errors:
        raise OrchestrationError("image générée mais restauration GPU échouée: " + "; ".join(restore_errors))
    if not png.startswith(b"\x89PNG\r\n\x1a\n"):
        raise OrchestrationError("sortie de génération non PNG")
    return png


def openai_error(message: str, code: str, status: int) -> tuple[int, dict[str, Any]]:
    return status, {"error": {"message": message, "type": "invalid_request_error", "code": code}}


class Handler(BaseHTTPRequestHandler):
    server_version = "FluxOrchestrator/1.0"

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write(f"[flux-api] {self.address_string()} {fmt % args}\n")

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_png(self, status: int, png: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(png)))
        self.send_header("Cache-Control", "private, no-store")
        self.end_headers()
        self.wfile.write(png)

    def check_auth(self) -> bool:
        try:
            ok = authorized(self.headers.get("Authorization"))
        except OrchestrationError as exc:
            self.send_json(500, {"error": {"message": str(exc), "type": "server_error", "code": "auth_config"}})
            return False
        if not ok:
            self.send_json(401, {"error": {"message": "Bearer invalide", "type": "authentication_error", "code": "invalid_api_key"}})
            return False
        return True

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/health":
            try:
                auth_enabled = bool(read_api_keys())
                self.send_json(200, {"status": "ok", "auth": auth_enabled})
            except OrchestrationError as exc:
                self.send_json(500, {"status": "error", "error": str(exc)})
            return
        if path.startswith("/v1/images/") and path.endswith(".png"):
            if not self.check_auth():
                return
            image_id = pathlib.PurePosixPath(path).name
            if len(image_id) != 36 or not image_id.endswith(".png"):
                self.send_json(404, {"error": {"message": "image absente", "type": "not_found", "code": "not_found"}})
                return
            image_path = OUTPUT_DIR / image_id
            if not image_path.is_file():
                self.send_json(404, {"error": {"message": "image absente", "type": "not_found", "code": "not_found"}})
                return
            self.send_png(200, image_path.read_bytes())
            return
        self.send_json(404, {"error": {"message": "route inconnue", "type": "not_found", "code": "not_found"}})

    def do_POST(self) -> None:  # noqa: N802
        if urlparse(self.path).path != "/v1/images/generations":
            self.send_json(404, {"error": {"message": "route inconnue", "type": "not_found", "code": "not_found"}})
            return
        if not self.check_auth():
            return
        try:
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                status, payload = openai_error("Content-Length invalide", "invalid_body", 400)
                self.send_json(status, payload)
                return
            if length <= 0 or length > 131_072:
                status, payload = openai_error("corps JSON absent ou trop grand", "invalid_body", 400)
                self.send_json(status, payload)
                return
            request = json.loads(self.rfile.read(length).decode("utf-8"))
            if not isinstance(request, dict):
                status, payload = openai_error("le corps JSON doit être un objet", "invalid_json", 400)
                self.send_json(status, payload)
                return
            prompt = request.get("prompt")
            if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 20_000:
                status, payload = openai_error("prompt requis (1 à 20000 caractères)", "invalid_prompt", 400)
                self.send_json(status, payload)
                return
            size = request.get("size", "1280x720")
            width = request.get("width", 1280)
            height = request.get("height", 720)
            if size != "1280x720" or width != 1280 or height != 720:
                status, payload = openai_error("seule la taille 1280x720 est supportée", "invalid_size", 400)
                self.send_json(status, payload)
                return
            if request.get("n", 1) != 1:
                status, payload = openai_error("n doit valoir 1", "invalid_n", 400)
                self.send_json(status, payload)
                return
            seed = request.get("seed")
            if seed is not None and (
                isinstance(seed, bool) or not isinstance(seed, int) or not 0 <= seed < 2**63
            ):
                status, payload = openai_error("seed invalide", "invalid_seed", 400)
                self.send_json(status, payload)
                return

            png = generate_png(prompt.strip(), seed)
            response_format = request.get("response_format", "b64_json")
            if response_format == "png" or "image/png" in self.headers.get("Accept", ""):
                self.send_png(200, png)
                return
            created = int(time.time())
            if response_format == "b64_json":
                self.send_json(200, {"created": created, "data": [{"b64_json": base64.b64encode(png).decode("ascii")} ]})
                return
            if response_format == "url":
                OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
                image_id = f"{uuid.uuid4().hex}.png"
                destination = OUTPUT_DIR / image_id
                temporary = OUTPUT_DIR / f".{image_id}.tmp"
                temporary.write_bytes(png)
                os.replace(temporary, destination)
                self.send_json(200, {"created": created, "data": [{"url": f"{PUBLIC_URL}/v1/images/{image_id}"}]})
                return
            status, payload = openai_error("response_format doit valoir b64_json, url ou png", "invalid_response_format", 400)
            self.send_json(status, payload)
        except (json.JSONDecodeError, UnicodeDecodeError):
            status, payload = openai_error("JSON invalide", "invalid_json", 400)
            self.send_json(status, payload)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as exc:
            self.send_json(500, {"error": {"message": str(exc), "type": "server_error", "code": "generation_failed"}})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=os.getenv("FLUX_ORCHESTRATOR_BIND", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.getenv("FLUX_ORCHESTRATOR_PORT", "8003")))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.host != "127.0.0.1":
        raise OrchestrationError("l'orchestrateur doit rester lié à 127.0.0.1")
    read_api_keys()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True

    def shutdown(_signum: int, _frame: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    server.serve_forever(poll_interval=0.5)
    server.server_close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, OrchestrationError) as exc:
        print(f"[flux-api] ERREUR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
