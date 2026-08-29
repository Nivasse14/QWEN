"""Read-only, fixed server diagnostics exposed as one OpenAPI tool."""

from __future__ import annotations

import shutil
from typing import Any

from .config import Settings
from .errors import CommandUnavailable
from .files import canonical_root, jailed_path, list_directory, read_regular_file
from .models import ServerCommand, ServerShellRequest
from .runner import CommandRunner


class ServerService:
    """Implement the server_shell allowlist without accepting raw commands."""

    def __init__(self, settings: Settings, runner: CommandRunner) -> None:
        self.settings = settings
        self.runner = runner

    def execute(self, request: ServerShellRequest) -> dict[str, Any]:
        """Execute exactly one allowlisted diagnostic operation."""

        root = canonical_root(self.settings)
        if request.command is ServerCommand.ls:
            target = jailed_path(
                root, request.path or ".", allow_root=True, block_git=True
            )
            return {
                "command": "ls",
                "path": str(target.relative_to(root)) or ".",
                "entries": list_directory(root, target),
            }
        if request.command is ServerCommand.cat:
            target = jailed_path(
                root, request.path or "", allow_root=False, block_git=True
            )
            return {
                "command": "cat",
                "path": str(target.relative_to(root)),
                "content": read_regular_file(
                    root, target, max_bytes=self.settings.max_cat_bytes
                ),
            }
        if request.command is ServerCommand.uptime:
            output = self.runner.run(
                ["uptime"], timeout=self.settings.command_timeout_seconds
            ).stdout
            return {"command": "uptime", "output": output}
        if request.command is ServerCommand.df:
            # A fresh volume may not have REPOS_ROOT yet. Inspect the mounted
            # parent rather than turning a read-only diagnostic into a mkdir.
            df_target = root if root.exists() else root.parent
            output = self.runner.run(
                ["df", "-h", str(df_target)],
                timeout=self.settings.command_timeout_seconds,
            ).stdout
            return {"command": "df", "output": output}
        if request.command is ServerCommand.docker_ps:
            if shutil.which("docker", path=self.settings.command_path) is None:
                raise CommandUnavailable("Docker CLI is not available")
            output = self.runner.run(
                [
                    "docker",
                    "ps",
                    "--format",
                    "{{json .}}",
                    "--no-trunc",
                ],
                timeout=self.settings.command_timeout_seconds,
            ).stdout
            return {"command": "docker_ps", "output": output}
        raise AssertionError("Unhandled server command")  # pragma: no cover
