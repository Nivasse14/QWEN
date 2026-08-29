from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from tools_api.config import Settings
from tools_api.flux import FluxResult
from tools_api.main import create_app
from tools_api.runner import CommandResult


INTERNAL_TOKEN = "test-internal-token-at-least-32-chars"


class FakeRunner:
    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def run(self, args: list[str], **kwargs: Any) -> CommandResult:
        self.calls.append({"args": list(args), **kwargs})
        if args[:3] == ["git", "rev-parse", "HEAD"]:
            output = "a" * 40 + "\n"
        elif args[:3] == ["git", "branch", "--show-current"]:
            output = "main\n"
        elif args[:2] == ["gh", "api"]:
            output = "[]"
        elif "--json" in args:
            output = "[]" if "list" in args else "{}"
        elif args[:3] in (["gh", "issue", "create"], ["gh", "pr", "create"]):
            output = "https://github.invalid/example/1\n"
        else:
            output = "ok\n"
        return CommandResult(stdout=output, stderr="", returncode=0)


class FakeFluxClient:
    def __init__(self) -> None:
        self.requests: list[Any] = []

    def generate(self, request: Any) -> FluxResult:
        self.requests.append(request)
        return FluxResult(content=b"\x89PNG\r\n\x1a\nTEST", media_type="image/png")


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        internal_bearer_token=INTERNAL_TOKEN,
        github_token="dummy-github-token",
        github_allowed_repos=frozenset({"owner/repo"}),
        repos_root=tmp_path / "repos",
        flux_orchestrator_token="dummy-flux-token",
        command_timeout_seconds=1,
        git_timeout_seconds=1,
    )


@pytest.fixture
def runner() -> FakeRunner:
    return FakeRunner()


@pytest.fixture
def flux() -> FakeFluxClient:
    return FakeFluxClient()


@pytest.fixture
def client(settings: Settings, runner: FakeRunner, flux: FakeFluxClient) -> TestClient:
    app = create_app(settings, runner=runner, flux_client=flux)
    return TestClient(app)


@pytest.fixture
def auth_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {INTERNAL_TOKEN}"}


@pytest.fixture
def cloned_repo(settings: Settings) -> Path:
    repository = settings.repos_root / "owner" / "repo"
    (repository / ".git").mkdir(parents=True)
    return repository

