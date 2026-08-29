"""Fixed GitHub and Git operations backed by the ``gh`` and ``git`` CLIs."""

from __future__ import annotations

import json
from pathlib import Path
import re
from typing import Any

from .config import Settings
from .errors import ConfigurationError, ConflictError, NotFoundError, UpstreamError
from .files import (
    allowed_repo,
    canonical_root,
    repo_file_path,
    repo_path,
    require_git_repo,
    write_utf8_file,
)
from .runner import CommandRunner


_COMMIT_PATTERN = re.compile(r"^[0-9a-fA-F]{7,64}$")
_BRANCH_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")


class GitHubService:
    """Expose only predefined GitHub and Git operations."""

    def __init__(self, settings: Settings, runner: CommandRunner) -> None:
        self.settings = settings
        self.runner = runner

    def _github_env(self) -> dict[str, str]:
        if not self.settings.github_token:
            raise ConfigurationError("GitHub authentication is not configured")
        return {
            "GH_TOKEN": self.settings.github_token,
            "GIT_CONFIG_GLOBAL": str(self.settings.git_config_global),
        }

    @staticmethod
    def _decode_json(output: str) -> Any:
        try:
            return json.loads(output)
        except json.JSONDecodeError as exc:
            raise UpstreamError("GitHub returned malformed JSON") from exc

    def _gh(self, args: list[str], *, timeout: int | None = None) -> str:
        result = self.runner.run(
            ["gh", *args],
            env=self._github_env(),
            timeout=timeout or self.settings.command_timeout_seconds,
        )
        return result.stdout

    def _git(self, repository: Path, args: list[str], *, timeout: int | None = None) -> str:
        result = self.runner.run(
            ["git", *args],
            cwd=repository,
            env=self._github_env(),
            timeout=timeout or self.settings.git_timeout_seconds,
        )
        return result.stdout

    def list_repositories(self, limit: int) -> list[dict[str, Any]]:
        """List accessible repositories, filtered to the configured allowlist."""

        output = self._gh(
            [
                "api",
                "--method",
                "GET",
                f"/user/repos?per_page={limit}&sort=updated",
            ]
        )
        payload = self._decode_json(output)
        if not isinstance(payload, list):
            raise UpstreamError("GitHub returned an unexpected repository response")
        allowed = self.settings.github_allowed_repos
        result: list[dict[str, Any]] = []
        for item in payload:
            if not isinstance(item, dict) or item.get("full_name") not in allowed:
                continue
            result.append(
                {
                    "name_with_owner": item.get("full_name"),
                    "description": item.get("description"),
                    "private": item.get("private"),
                    "url": item.get("html_url"),
                    "default_branch": item.get("default_branch"),
                }
            )
        return result

    def clone_repository(self, slug: str) -> dict[str, Any]:
        """Clone an allowlisted repository into its deterministic jailed path."""

        slug = allowed_repo(self.settings, slug)
        root = canonical_root(self.settings)
        root.mkdir(mode=0o755, parents=True, exist_ok=True)
        destination = repo_path(self.settings, slug)
        destination.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        if destination.parent.is_symlink():
            raise ConflictError("Repository owner directory cannot be a symbolic link")
        if destination.exists() or destination.is_symlink():
            raise ConflictError("Repository destination already exists")
        self._gh(
            ["repo", "clone", slug, str(destination), "--", "--depth=1"],
            timeout=self.settings.git_timeout_seconds,
        )
        if not (destination / ".git").is_dir():
            raise UpstreamError("Clone completed without a Git repository")
        return {
            "repository": slug,
            "path": str(destination.relative_to(root)),
            "status": "cloned",
        }

    def status(self, slug: str) -> dict[str, Any]:
        """Return bounded porcelain status for a cloned repository."""

        repository = require_git_repo(self.settings, slug)
        output = self._git(
            repository,
            ["status", "--short", "--branch", "--untracked-files=normal"],
        )
        return {"repository": allowed_repo(self.settings, slug), "status": output}

    def write_text(self, slug: str, relative_path: str, content: str) -> dict[str, Any]:
        """Write one bounded UTF-8 file under a cloned repository."""

        repository, target = repo_file_path(self.settings, slug, relative_path)
        size = write_utf8_file(
            repository,
            target,
            content,
            max_bytes=self.settings.max_text_file_bytes,
        )
        return {
            "repository": allowed_repo(self.settings, slug),
            "path": target.relative_to(repository).as_posix(),
            "bytes_written": size,
        }

    @staticmethod
    def _valid_current_branch(value: str) -> bool:
        return bool(
            _BRANCH_PATTERN.fullmatch(value)
            and ".." not in value
            and "@{" not in value
            and not value.endswith(("/", "."))
        )

    def commit_and_push(
        self,
        slug: str,
        paths: list[str],
        message: str,
        *,
        push: bool,
    ) -> dict[str, Any]:
        """Stage exact paths, commit once, and optionally push without force."""

        repository = require_git_repo(self.settings, slug)
        normalized_paths: list[str] = []
        for relative_path in paths:
            _, target = repo_file_path(self.settings, slug, relative_path)
            if not target.is_file() or target.is_symlink():
                raise NotFoundError(f"File is missing or unsafe: {relative_path}")
            normalized_paths.append(target.relative_to(repository).as_posix())

        self._git(repository, ["add", "--", *normalized_paths])
        self._git(
            repository,
            [
                "-c",
                f"user.name={self.settings.git_author_name}",
                "-c",
                f"user.email={self.settings.git_author_email}",
                "commit",
                "-m",
                message,
            ],
        )
        commit = self._git(repository, ["rev-parse", "HEAD"]).strip()
        if not _COMMIT_PATTERN.fullmatch(commit):
            raise UpstreamError("Git returned an invalid commit identifier")

        branch = self._git(repository, ["branch", "--show-current"]).strip()
        if not self._valid_current_branch(branch):
            raise ConflictError("Repository is detached or has an unsafe branch name")
        if push:
            self._git(
                repository,
                ["push", "origin", f"HEAD:refs/heads/{branch}"],
                timeout=self.settings.git_timeout_seconds,
            )
        return {
            "repository": allowed_repo(self.settings, slug),
            "commit": commit,
            "branch": branch,
            "pushed": push,
            "paths": normalized_paths,
        }

    def list_issues(self, slug: str, state: str, limit: int) -> list[dict[str, Any]]:
        """List issues for an allowlisted repository."""

        slug = allowed_repo(self.settings, slug)
        output = self._gh(
            [
                "issue",
                "list",
                "--repo",
                slug,
                "--state",
                state,
                "--limit",
                str(limit),
                "--json",
                "number,title,state,url,author,createdAt,updatedAt,labels",
            ]
        )
        payload = self._decode_json(output)
        if not isinstance(payload, list):
            raise UpstreamError("GitHub returned an unexpected issue response")
        return payload

    def get_issue(self, slug: str, number: int) -> dict[str, Any]:
        """Read one issue from an allowlisted repository."""

        slug = allowed_repo(self.settings, slug)
        output = self._gh(
            [
                "issue",
                "view",
                str(number),
                "--repo",
                slug,
                "--json",
                "number,title,body,state,url,author,createdAt,updatedAt,labels,comments",
            ]
        )
        payload = self._decode_json(output)
        if not isinstance(payload, dict):
            raise UpstreamError("GitHub returned an unexpected issue response")
        return payload

    def create_issue(self, slug: str, title: str, body: str) -> dict[str, str]:
        """Create one issue and return its GitHub URL."""

        slug = allowed_repo(self.settings, slug)
        url = self._gh(
            [
                "issue",
                "create",
                "--repo",
                slug,
                "--title",
                title,
                "--body",
                body,
            ]
        ).strip()
        return {"repository": slug, "url": url}

    def list_pull_requests(
        self, slug: str, state: str, limit: int
    ) -> list[dict[str, Any]]:
        """List pull requests for an allowlisted repository."""

        slug = allowed_repo(self.settings, slug)
        output = self._gh(
            [
                "pr",
                "list",
                "--repo",
                slug,
                "--state",
                state,
                "--limit",
                str(limit),
                "--json",
                "number,title,state,url,author,headRefName,baseRefName,isDraft,createdAt,updatedAt",
            ]
        )
        payload = self._decode_json(output)
        if not isinstance(payload, list):
            raise UpstreamError("GitHub returned an unexpected pull request response")
        return payload

    def get_pull_request(self, slug: str, number: int) -> dict[str, Any]:
        """Read one pull request from an allowlisted repository."""

        slug = allowed_repo(self.settings, slug)
        output = self._gh(
            [
                "pr",
                "view",
                str(number),
                "--repo",
                slug,
                "--json",
                "number,title,body,state,url,author,headRefName,baseRefName,isDraft,createdAt,updatedAt,commits,comments,reviews",
            ]
        )
        payload = self._decode_json(output)
        if not isinstance(payload, dict):
            raise UpstreamError("GitHub returned an unexpected pull request response")
        return payload

    def create_pull_request(
        self,
        slug: str,
        *,
        title: str,
        body: str,
        head: str,
        base: str,
        draft: bool,
    ) -> dict[str, str]:
        """Create a pull request between two existing, validated branches."""

        slug = allowed_repo(self.settings, slug)
        args = [
            "pr",
            "create",
            "--repo",
            slug,
            "--title",
            title,
            "--body",
            body,
            "--head",
            head,
            "--base",
            base,
        ]
        if draft:
            args.append("--draft")
        url = self._gh(args).strip()
        return {"repository": slug, "url": url}
