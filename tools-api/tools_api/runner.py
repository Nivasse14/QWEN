"""Bounded subprocess execution with no shell interpretation."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import signal
import subprocess
import threading
from typing import Mapping, Sequence

from .errors import (
    CommandFailed,
    CommandOutputTooLarge,
    CommandTimedOut,
    CommandUnavailable,
)


@dataclass(frozen=True, slots=True)
class CommandResult:
    """Sanitized output from a completed command."""

    stdout: str
    stderr: str
    returncode: int


class CommandRunner:
    """Run argv-only commands with bounded time, output and environment."""

    def __init__(
        self,
        *,
        command_path: str,
        default_timeout: int = 30,
        max_output_bytes: int = 512 * 1024,
        secrets: Sequence[str] = (),
    ) -> None:
        self.command_path = command_path
        self.default_timeout = default_timeout
        self.max_output_bytes = max_output_bytes
        self.secrets = tuple(value for value in secrets if value)

    def _redact(self, value: str) -> str:
        for secret in self.secrets:
            value = value.replace(secret, "[REDACTED]")
        return value

    @staticmethod
    def _kill_process_group(process: subprocess.Popen[bytes]) -> None:
        if process.poll() is not None:
            return
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:  # pragma: no cover - Linux is the production target.
                process.kill()
        except ProcessLookupError:
            pass

    def run(
        self,
        args: Sequence[str],
        *,
        cwd: Path | None = None,
        env: Mapping[str, str] | None = None,
        timeout: int | float | None = None,
        max_output_bytes: int | None = None,
    ) -> CommandResult:
        """Execute an argv sequence with ``shell=False`` and strict bounds."""

        argv = list(args)
        if not argv or any(not isinstance(arg, str) or "\x00" in arg for arg in argv):
            raise ValueError("Command arguments must be non-empty strings")

        limit = max_output_bytes or self.max_output_bytes
        if limit <= 0:
            raise ValueError("Output limit must be positive")
        command_env = {
            "PATH": self.command_path,
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "GIT_TERMINAL_PROMPT": "0",
            "GH_PROMPT_DISABLED": "1",
        }
        if env:
            command_env.update({str(key): str(value) for key, value in env.items()})

        try:
            process = subprocess.Popen(
                argv,
                cwd=str(cwd) if cwd else None,
                env=command_env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                shell=False,
                start_new_session=True,
            )
        except FileNotFoundError as exc:
            raise CommandUnavailable() from exc

        buffers = {"stdout": bytearray(), "stderr": bytearray()}
        total = 0
        lock = threading.Lock()
        overflow = threading.Event()

        def drain(name: str, pipe: object) -> None:
            nonlocal total
            stream = pipe
            try:
                while True:
                    chunk = stream.read(64 * 1024)  # type: ignore[attr-defined]
                    if not chunk:
                        break
                    with lock:
                        total += len(chunk)
                        remaining = max(0, limit - len(buffers[name]))
                        buffers[name].extend(chunk[:remaining])
                        if total > limit:
                            overflow.set()
                            self._kill_process_group(process)
                            break
            finally:
                stream.close()  # type: ignore[attr-defined]

        stdout_thread = threading.Thread(
            target=drain, args=("stdout", process.stdout), daemon=True
        )
        stderr_thread = threading.Thread(
            target=drain, args=("stderr", process.stderr), daemon=True
        )
        stdout_thread.start()
        stderr_thread.start()

        try:
            process.wait(timeout=timeout or self.default_timeout)
        except subprocess.TimeoutExpired as exc:
            self._kill_process_group(process)
            process.wait()
            stdout_thread.join(timeout=1)
            stderr_thread.join(timeout=1)
            raise CommandTimedOut() from exc

        stdout_thread.join(timeout=1)
        stderr_thread.join(timeout=1)
        if overflow.is_set():
            raise CommandOutputTooLarge()

        stdout = self._redact(buffers["stdout"].decode("utf-8", errors="replace"))
        stderr = self._redact(buffers["stderr"].decode("utf-8", errors="replace"))
        if process.returncode:
            raise CommandFailed(process.returncode, stderr)
        return CommandResult(stdout=stdout, stderr=stderr, returncode=0)

