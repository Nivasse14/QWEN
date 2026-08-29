from __future__ import annotations

import sys

import pytest

from tools_api.errors import CommandFailed, CommandOutputTooLarge, CommandTimedOut
from tools_api.runner import CommandRunner


def test_runner_redacts_secrets_and_uses_argv() -> None:
    runner = CommandRunner(
        command_path="/usr/local/bin:/usr/bin:/bin",
        default_timeout=2,
        max_output_bytes=1024,
        secrets=("dummy-secret",),
    )
    result = runner.run([sys.executable, "-c", "print('dummy-secret')"])
    assert result.stdout.strip() == "[REDACTED]"


def test_runner_redacts_gh_token_from_failed_command() -> None:
    token = "dummy-github-token"
    runner = CommandRunner(
        command_path="/usr/local/bin:/usr/bin:/bin",
        default_timeout=2,
        max_output_bytes=1024,
        secrets=(token,),
    )
    with pytest.raises(CommandFailed) as caught:
        runner.run(
            [
                sys.executable,
                "-c",
                "import os, sys; sys.stderr.write(os.environ['GH_TOKEN']); sys.exit(7)",
            ],
            env={"GH_TOKEN": token},
        )
    assert token not in str(caught.value)
    assert "[REDACTED]" in str(caught.value)


def test_runner_enforces_output_limit() -> None:
    runner = CommandRunner(
        command_path="/usr/local/bin:/usr/bin:/bin",
        default_timeout=2,
        max_output_bytes=128,
    )
    with pytest.raises(CommandOutputTooLarge):
        runner.run([sys.executable, "-c", "print('x' * 10000)"])


def test_runner_enforces_timeout() -> None:
    runner = CommandRunner(
        command_path="/usr/local/bin:/usr/bin:/bin",
        default_timeout=1,
        max_output_bytes=128,
    )
    with pytest.raises(CommandTimedOut):
        runner.run(
            [sys.executable, "-c", "import time; time.sleep(2)"], timeout=0.05
        )
