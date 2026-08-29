"""FastAPI application exposing a deliberately small OpenAPI tool surface."""

from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Depends, FastAPI, Query
from fastapi.responses import JSONResponse, Response

from .config import Settings
from .errors import ToolsAPIError
from .flux import FluxClient, FluxResult
from .github import GitHubService
from .models import (
    CloneRepositoryRequest,
    CommitPushRequest,
    FluxImageRequest,
    IssueCreateRequest,
    PullRequestCreateRequest,
    ServerShellRequest,
    StateFilter,
    WriteTextRequest,
)
from .runner import CommandRunner
from .security import require_internal_bearer
from .server import ServerService


def create_app(
    settings: Settings | None = None,
    *,
    runner: CommandRunner | None = None,
    flux_client: FluxClient | None = None,
) -> FastAPI:
    """Create the service with injectable local dependencies for unit tests."""

    settings = settings or Settings.from_env()
    runner = runner or CommandRunner(
        command_path=settings.command_path,
        default_timeout=settings.command_timeout_seconds,
        max_output_bytes=settings.max_command_output_bytes,
        secrets=settings.secret_values,
    )
    flux_client = flux_client or FluxClient(settings)

    app = FastAPI(
        title="AI Phone Stack Tools API",
        version="1.0.0",
        description=(
            "Restricted OpenAPI tools for Open WebUI. All mutating repository "
            "operations are limited to GITHUB_ALLOWED_REPOS and REPOS_ROOT."
        ),
    )
    app.state.settings = settings
    app.state.github = GitHubService(settings, runner)
    app.state.server = ServerService(settings, runner)
    app.state.flux = flux_client

    @app.exception_handler(ToolsAPIError)
    async def tools_api_error_handler(_request: Any, exc: ToolsAPIError) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content={"detail": exc.message})

    @app.get(
        "/healthz",
        tags=["service"],
        summary="Container health check",
        operation_id="tools_api_health",
        include_in_schema=False,
    )
    def health() -> dict[str, str]:
        """Return liveness only; no configuration or secret state is disclosed."""

        return {"status": "ok"}

    router = APIRouter(dependencies=[Depends(require_internal_bearer)])

    @router.get(
        "/github/repos",
        tags=["github"],
        summary="List allowlisted GitHub repositories",
        operation_id="github_list_repos",
    )
    def github_list_repos(
        limit: Annotated[int, Query(ge=1, le=100)] = 100,
    ) -> list[dict[str, Any]]:
        """List repositories visible to the token, filtered to the server allowlist."""

        return app.state.github.list_repositories(limit)

    @router.post(
        "/github/clone",
        tags=["github"],
        summary="Clone one allowlisted repository",
        operation_id="github_clone",
    )
    def github_clone(request: CloneRepositoryRequest) -> dict[str, Any]:
        """Clone to REPOS_ROOT/owner/repository without accepting a destination path."""

        return app.state.github.clone_repository(request.repository)

    @router.get(
        "/github/status",
        tags=["github"],
        summary="Read repository Git status",
        operation_id="github_status",
    )
    def github_status(repository: Annotated[str, Query(min_length=3, max_length=200)]) -> dict[str, Any]:
        """Return short, bounded Git status for an allowlisted local clone."""

        return app.state.github.status(repository)

    @router.post(
        "/github/write-text",
        tags=["github"],
        summary="Write a UTF-8 repository file",
        operation_id="github_write_text",
    )
    def github_write_text(request: WriteTextRequest) -> dict[str, Any]:
        """Atomically write bounded text while blocking traversal, .git and symlinks."""

        return app.state.github.write_text(
            request.repository, request.path, request.content
        )

    @router.post(
        "/github/commit-push",
        tags=["github"],
        summary="Commit exact files and optionally push",
        operation_id="github_commit_push",
    )
    def github_commit_push(request: CommitPushRequest) -> dict[str, Any]:
        """Stage exact paths, create one commit and push without force."""

        return app.state.github.commit_and_push(
            request.repository,
            request.paths,
            request.message,
            push=request.push,
        )

    @router.get(
        "/github/issues",
        tags=["github"],
        summary="List repository issues",
        operation_id="github_list_issues",
    )
    def github_list_issues(
        repository: Annotated[str, Query(min_length=3, max_length=200)],
        state: StateFilter = StateFilter.open,
        limit: Annotated[int, Query(ge=1, le=100)] = 30,
    ) -> list[dict[str, Any]]:
        """List issues from an allowlisted repository with a bounded result count."""

        return app.state.github.list_issues(repository, state.value, limit)

    @router.get(
        "/github/issues/{number}",
        tags=["github"],
        summary="Read one repository issue",
        operation_id="github_get_issue",
    )
    def github_get_issue(
        number: int,
        repository: Annotated[str, Query(min_length=3, max_length=200)],
    ) -> dict[str, Any]:
        """Read one issue, including bounded metadata returned by GitHub CLI."""

        if number < 1:
            from fastapi import HTTPException

            raise HTTPException(status_code=422, detail="Issue number must be positive")
        return app.state.github.get_issue(repository, number)

    @router.post(
        "/github/issues",
        tags=["github"],
        summary="Create one repository issue",
        operation_id="github_create_issue",
    )
    def github_create_issue(request: IssueCreateRequest) -> dict[str, str]:
        """Create an issue in an allowlisted repository and return its URL."""

        return app.state.github.create_issue(
            request.repository, request.title, request.body
        )

    @router.get(
        "/github/pulls",
        tags=["github"],
        summary="List repository pull requests",
        operation_id="github_list_pull_requests",
    )
    def github_list_pull_requests(
        repository: Annotated[str, Query(min_length=3, max_length=200)],
        state: StateFilter = StateFilter.open,
        limit: Annotated[int, Query(ge=1, le=100)] = 30,
    ) -> list[dict[str, Any]]:
        """List pull requests from an allowlisted repository."""

        return app.state.github.list_pull_requests(repository, state.value, limit)

    @router.get(
        "/github/pulls/{number}",
        tags=["github"],
        summary="Read one repository pull request",
        operation_id="github_get_pull_request",
    )
    def github_get_pull_request(
        number: int,
        repository: Annotated[str, Query(min_length=3, max_length=200)],
    ) -> dict[str, Any]:
        """Read one pull request from an allowlisted repository."""

        if number < 1:
            from fastapi import HTTPException

            raise HTTPException(status_code=422, detail="Pull request number must be positive")
        return app.state.github.get_pull_request(repository, number)

    @router.post(
        "/github/pulls",
        tags=["github"],
        summary="Create one pull request",
        operation_id="github_create_pull_request",
    )
    def github_create_pull_request(
        request: PullRequestCreateRequest,
    ) -> dict[str, str]:
        """Create a pull request between two validated existing branch names."""

        return app.state.github.create_pull_request(
            request.repository,
            title=request.title,
            body=request.body,
            head=request.head,
            base=request.base,
            draft=request.draft,
        )

    @router.post(
        "/server_shell",
        tags=["server"],
        summary="Run one fixed, read-only server diagnostic",
        operation_id="server_shell",
    )
    def server_shell(request: ServerShellRequest) -> dict[str, Any]:
        """Run ls/cat in REPOS_ROOT, uptime, df, or fixed docker ps if available."""

        return app.state.server.execute(request)

    @router.post(
        "/flux_image",
        tags=["images"],
        summary="Generate an image through the private FLUX orchestrator",
        operation_id="flux_image",
        responses={
            200: {
                "description": "A PNG image or orchestrator JSON containing its file URL.",
                "content": {
                    "image/png": {"schema": {"type": "string", "format": "binary"}},
                    "application/json": {"schema": {"type": "object"}},
                },
            }
        },
    )
    def flux_image(request: FluxImageRequest) -> Response:
        """Proxy a bounded 1280x720-by-default request to local GPU orchestration."""

        result: FluxResult = app.state.flux.generate(request)
        if result.media_type == "image/png":
            return Response(content=result.content, media_type="image/png")
        return JSONResponse(content=result.content)

    app.include_router(router)
    return app

