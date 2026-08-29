from __future__ import annotations

import os
from pathlib import Path

from fastapi.testclient import TestClient

from tools_api.config import Settings
from tools_api.main import create_app

from conftest import FakeFluxClient, FakeRunner, INTERNAL_TOKEN


def test_health_is_public_but_tools_require_bearer(client: TestClient) -> None:
    assert client.get("/healthz").json() == {"status": "ok"}
    assert client.get("/github/repos").status_code == 401
    assert (
        client.get(
            "/github/repos", headers={"Authorization": "Bearer definitely-wrong"}
        ).status_code
        == 401
    )


def test_missing_server_token_fails_closed(
    settings: Settings, runner: FakeRunner, flux: FakeFluxClient
) -> None:
    insecure = Settings(
        internal_bearer_token="",
        github_token=settings.github_token,
        github_allowed_repos=settings.github_allowed_repos,
        repos_root=settings.repos_root,
        flux_orchestrator_token=settings.flux_orchestrator_token,
    )
    client = TestClient(create_app(insecure, runner=runner, flux_client=flux))
    response = client.get(
        "/github/repos", headers={"Authorization": f"Bearer {INTERNAL_TOKEN}"}
    )
    assert response.status_code == 503


def test_openapi_exposes_fixed_operations_and_bearer_scheme(client: TestClient) -> None:
    document = client.get("/openapi.json").json()
    operation_ids = {
        operation["operationId"]
        for path in document["paths"].values()
        for operation in path.values()
    }
    assert {
        "github_list_repos",
        "github_clone",
        "github_write_text",
        "github_commit_push",
        "github_create_issue",
        "github_create_pull_request",
        "server_shell",
        "flux_image",
    } <= operation_ids
    assert "InternalBearer" in document["components"]["securitySchemes"]


def test_write_text_is_jailed_and_blocks_git_metadata(
    client: TestClient,
    auth_headers: dict[str, str],
    cloned_repo: Path,
) -> None:
    valid = client.post(
        "/github/write-text",
        headers=auth_headers,
        json={"repository": "owner/repo", "path": "docs/test.txt", "content": "ok"},
    )
    assert valid.status_code == 200
    assert (cloned_repo / "docs" / "test.txt").read_text() == "ok"

    for path in ("../escape.txt", ".git/config", "/tmp/escape.txt"):
        response = client.post(
            "/github/write-text",
            headers=auth_headers,
            json={"repository": "owner/repo", "path": path, "content": "blocked"},
        )
        assert response.status_code == 400, path
    assert not (cloned_repo.parent / "escape.txt").exists()


def test_write_rejects_symlink_escape(
    client: TestClient,
    auth_headers: dict[str, str],
    cloned_repo: Path,
    tmp_path: Path,
) -> None:
    outside = tmp_path / "outside"
    outside.mkdir()
    os.symlink(outside, cloned_repo / "linked")
    response = client.post(
        "/github/write-text",
        headers=auth_headers,
        json={
            "repository": "owner/repo",
            "path": "linked/escape.txt",
            "content": "blocked",
        },
    )
    assert response.status_code == 400
    assert not (outside / "escape.txt").exists()


def test_repo_allowlist_is_fail_closed(
    client: TestClient, auth_headers: dict[str, str], runner: FakeRunner
) -> None:
    response = client.post(
        "/github/clone",
        headers=auth_headers,
        json={"repository": "someone/else"},
    )
    assert response.status_code == 403
    assert runner.calls == []


def test_commit_stages_exact_paths_and_pushes_without_force(
    client: TestClient,
    auth_headers: dict[str, str],
    cloned_repo: Path,
    runner: FakeRunner,
) -> None:
    (cloned_repo / "test.txt").write_text("content")
    response = client.post(
        "/github/commit-push",
        headers=auth_headers,
        json={
            "repository": "owner/repo",
            "paths": ["test.txt"],
            "message": "Add test file",
            "push": True,
        },
    )
    assert response.status_code == 200, response.text
    assert response.json()["commit"] == "a" * 40
    commands = [call["args"] for call in runner.calls]
    assert ["git", "add", "--", "test.txt"] in commands
    assert ["git", "push", "origin", "HEAD:refs/heads/main"] in commands
    assert all("--force" not in command for command in commands)
    git_calls = [call for call in runner.calls if call["args"][0] == "git"]
    assert git_calls
    assert all(
        call["env"] == {"GH_TOKEN": "dummy-github-token"} for call in git_calls
    )
    assert all("dummy-github-token" not in call["args"] for call in git_calls)


def test_status_passes_gh_token_only_via_environment(
    client: TestClient,
    auth_headers: dict[str, str],
    cloned_repo: Path,
    runner: FakeRunner,
) -> None:
    response = client.get(
        "/github/status",
        headers=auth_headers,
        params={"repository": "owner/repo"},
    )
    assert response.status_code == 200
    call = runner.calls[-1]
    assert call["args"] == [
        "git",
        "status",
        "--short",
        "--branch",
        "--untracked-files=normal",
    ]
    assert call["env"] == {"GH_TOKEN": "dummy-github-token"}
    assert "dummy-github-token" not in call["args"]


def test_server_shell_has_no_raw_command_and_cat_is_jailed(
    client: TestClient,
    auth_headers: dict[str, str],
    cloned_repo: Path,
    runner: FakeRunner,
) -> None:
    (cloned_repo / "hello.txt").write_text("hello")
    response = client.post(
        "/server_shell",
        headers=auth_headers,
        json={"command": "cat", "path": "owner/repo/hello.txt"},
    )
    assert response.status_code == 200
    assert response.json()["content"] == "hello"

    traversal = client.post(
        "/server_shell",
        headers=auth_headers,
        json={"command": "cat", "path": "../outside"},
    )
    assert traversal.status_code == 400
    arbitrary = client.post(
        "/server_shell",
        headers=auth_headers,
        json={"command": "bash", "path": "whoami"},
    )
    assert arbitrary.status_code == 422

    uptime = client.post(
        "/server_shell", headers=auth_headers, json={"command": "uptime"}
    )
    assert uptime.status_code == 200
    assert runner.calls[-1]["args"] == ["uptime"]


def test_issue_and_pr_commands_are_fixed(
    client: TestClient,
    auth_headers: dict[str, str],
    runner: FakeRunner,
) -> None:
    issue = client.post(
        "/github/issues",
        headers=auth_headers,
        json={"repository": "owner/repo", "title": "Title", "body": "Body"},
    )
    assert issue.status_code == 200
    assert runner.calls[-1]["args"][:3] == ["gh", "issue", "create"]

    pull = client.post(
        "/github/pulls",
        headers=auth_headers,
        json={
            "repository": "owner/repo",
            "title": "PR",
            "body": "Body",
            "head": "feature/safe",
            "base": "main",
            "draft": False,
        },
    )
    assert pull.status_code == 200
    assert runner.calls[-1]["args"][:3] == ["gh", "pr", "create"]


def test_flux_defaults_to_1280_by_720(
    client: TestClient,
    auth_headers: dict[str, str],
    flux: FakeFluxClient,
) -> None:
    response = client.post(
        "/flux_image", headers=auth_headers, json={"prompt": "cat astronaut"}
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("image/png")
    assert flux.requests[0].width == 1280
    assert flux.requests[0].height == 720

    oversized = client.post(
        "/flux_image",
        headers=auth_headers,
        json={"prompt": "x", "width": 1920, "height": 1920},
    )
    assert oversized.status_code == 422
