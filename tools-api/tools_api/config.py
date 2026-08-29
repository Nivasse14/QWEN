"""Runtime configuration loaded exclusively from environment variables."""

from __future__ import annotations

from dataclasses import dataclass, field
import os
from pathlib import Path
import re
from urllib.parse import urlsplit


REPO_SLUG_PATTERN = re.compile(
    r"^(?P<owner>[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,98}[A-Za-z0-9])?)/"
    r"(?P<repo>[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,98}[A-Za-z0-9])?)$"
)


def normalize_repo_slug(value: str) -> str:
    """Return a normalized ``owner/repository`` slug or raise ``ValueError``."""

    slug = value.strip()
    match = REPO_SLUG_PATTERN.fullmatch(slug)
    if not match:
        raise ValueError("Repository must use the owner/repository form")
    if any(part in {".", ".."} for part in (match["owner"], match["repo"])):
        raise ValueError("Invalid repository name")
    return f"{match['owner']}/{match['repo']}"


def _parse_repo_allowlist(raw: str) -> frozenset[str]:
    if not raw.strip():
        return frozenset()
    return frozenset(normalize_repo_slug(item) for item in raw.split(",") if item.strip())


def _positive_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    value = int(raw)
    if value <= 0:
        raise ValueError(f"{name} must be positive")
    return value


def _validate_http_url(value: str) -> str:
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("FLUX_ORCHESTRATOR_URL must be an http(s) URL")
    if parsed.username or parsed.password or parsed.fragment:
        raise ValueError("FLUX_ORCHESTRATOR_URL cannot contain credentials or a fragment")
    return value.rstrip("/")


@dataclass(frozen=True, slots=True)
class Settings:
    """Security-sensitive service configuration.

    Secret fields are excluded from ``repr`` so accidental logging of the
    settings object does not reveal credentials.
    """

    internal_bearer_token: str = field(default="", repr=False)
    github_token: str = field(default="", repr=False)
    github_allowed_repos: frozenset[str] = field(default_factory=frozenset)
    repos_root: Path = Path("/workspace/repos")
    flux_orchestrator_url: str = "http://gpu-orchestrator:8001/v1/images/generations"
    flux_orchestrator_token: str = field(default="", repr=False)
    command_timeout_seconds: int = 30
    git_timeout_seconds: int = 120
    flux_timeout_seconds: int = 600
    max_command_output_bytes: int = 512 * 1024
    max_text_file_bytes: int = 1024 * 1024
    max_cat_bytes: int = 256 * 1024
    max_flux_response_bytes: int = 32 * 1024 * 1024
    git_author_name: str = "Open WebUI Agent"
    git_author_email: str = "open-webui-agent@localhost"
    command_path: str = "/usr/local/bin:/usr/bin:/bin"

    @classmethod
    def from_env(cls) -> "Settings":
        """Build settings without ever accepting credentials in API payloads."""

        return cls(
            internal_bearer_token=os.getenv("TOOLS_API_BEARER_TOKEN", ""),
            github_token=os.getenv("GITHUB_TOKEN", os.getenv("GITHUB_PAT", "")),
            github_allowed_repos=_parse_repo_allowlist(
                os.getenv("GITHUB_ALLOWED_REPOS", "")
            ),
            repos_root=Path(os.getenv("REPOS_ROOT", "/workspace/repos")),
            flux_orchestrator_url=_validate_http_url(
                os.getenv(
                    "FLUX_ORCHESTRATOR_URL",
                    "http://gpu-orchestrator:8001/v1/images/generations",
                )
            ),
            flux_orchestrator_token=os.getenv("FLUX_ORCHESTRATOR_TOKEN", ""),
            command_timeout_seconds=_positive_int("COMMAND_TIMEOUT_SECONDS", 30),
            git_timeout_seconds=_positive_int("GIT_TIMEOUT_SECONDS", 120),
            flux_timeout_seconds=_positive_int("FLUX_TIMEOUT_SECONDS", 600),
            max_command_output_bytes=_positive_int(
                "MAX_COMMAND_OUTPUT_BYTES", 512 * 1024
            ),
            max_text_file_bytes=_positive_int("MAX_TEXT_FILE_BYTES", 1024 * 1024),
            max_cat_bytes=_positive_int("MAX_CAT_BYTES", 256 * 1024),
            max_flux_response_bytes=_positive_int(
                "MAX_FLUX_RESPONSE_BYTES", 32 * 1024 * 1024
            ),
            git_author_name=os.getenv("GIT_AUTHOR_NAME", "Open WebUI Agent"),
            git_author_email=os.getenv(
                "GIT_AUTHOR_EMAIL", "open-webui-agent@localhost"
            ),
            command_path=os.getenv(
                "TOOLS_COMMAND_PATH", "/usr/local/bin:/usr/bin:/bin"
            ),
        )

    @property
    def secret_values(self) -> tuple[str, ...]:
        """Secrets that must be scrubbed from subprocess diagnostics."""

        return tuple(
            value
            for value in (
                self.internal_bearer_token,
                self.github_token,
                self.flux_orchestrator_token,
            )
            if value
        )

