"""Strict request models exposed through OpenAPI."""

from __future__ import annotations

from enum import Enum
import re
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from .config import normalize_repo_slug


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


RepoSlug = Annotated[
    str,
    Field(
        min_length=3,
        max_length=200,
        description="Allowlisted GitHub repository in owner/repository form.",
        examples=["example-owner/example-repository"],
    ),
]


def _validated_repo(value: str) -> str:
    return normalize_repo_slug(value)


class CloneRepositoryRequest(StrictModel):
    repository: RepoSlug

    _repo_validator = field_validator("repository")(_validated_repo)


class WriteTextRequest(StrictModel):
    repository: RepoSlug
    path: str = Field(
        min_length=1,
        max_length=512,
        description="UTF-8 file path relative to the cloned repository.",
        examples=["docs/notes.txt"],
    )
    content: str = Field(
        max_length=1_048_576,
        description="UTF-8 text to write. Runtime byte limits also apply.",
    )

    _repo_validator = field_validator("repository")(_validated_repo)


class CommitPushRequest(StrictModel):
    repository: RepoSlug
    paths: list[str] = Field(
        min_length=1,
        max_length=50,
        description="Exact repository-relative files to stage; globbing is never used.",
    )
    message: str = Field(
        min_length=1,
        max_length=200,
        description="Single-line commit message.",
    )
    push: bool = Field(
        default=True,
        description="Push the new commit to the current branch without force.",
    )

    _repo_validator = field_validator("repository")(_validated_repo)

    @field_validator("paths")
    @classmethod
    def unique_paths(cls, value: list[str]) -> list[str]:
        if len(set(value)) != len(value):
            raise ValueError("paths must not contain duplicates")
        if any(not item or len(item) > 512 for item in value):
            raise ValueError("each path must contain 1 to 512 characters")
        return value

    @field_validator("message")
    @classmethod
    def single_line_message(cls, value: str) -> str:
        if "\n" in value or "\r" in value or "\x00" in value:
            raise ValueError("commit message must be a single line")
        return value


class IssueCreateRequest(StrictModel):
    repository: RepoSlug
    title: str = Field(min_length=1, max_length=256)
    body: str = Field(default="", max_length=32_000)

    _repo_validator = field_validator("repository")(_validated_repo)


class PullRequestCreateRequest(StrictModel):
    repository: RepoSlug
    title: str = Field(min_length=1, max_length=256)
    body: str = Field(default="", max_length=32_000)
    head: str = Field(
        min_length=1,
        max_length=255,
        description="Existing source branch name.",
    )
    base: str = Field(
        min_length=1,
        max_length=255,
        description="Existing target branch name.",
    )
    draft: bool = False

    _repo_validator = field_validator("repository")(_validated_repo)

    @field_validator("head", "base")
    @classmethod
    def validate_branch(cls, value: str) -> str:
        if (
            not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", value)
            or ".." in value
            or "@{" in value
            or value.endswith(("/", "."))
            or value.startswith("-")
        ):
            raise ValueError("invalid Git branch name")
        return value


class ServerCommand(str, Enum):
    ls = "ls"
    cat = "cat"
    uptime = "uptime"
    df = "df"
    docker_ps = "docker_ps"


class ServerShellRequest(StrictModel):
    command: ServerCommand = Field(description="One fixed diagnostic operation.")
    path: str | None = Field(
        default=None,
        max_length=1024,
        description=(
            "Path under REPOS_ROOT. Required for cat, optional for ls, and "
            "forbidden for every other command."
        ),
    )

    @model_validator(mode="after")
    def validate_path_usage(self) -> "ServerShellRequest":
        if self.command is ServerCommand.cat and not self.path:
            raise ValueError("path is required for cat")
        if self.command not in {ServerCommand.cat, ServerCommand.ls} and self.path:
            raise ValueError("path is only accepted for ls and cat")
        return self


class FluxImageRequest(StrictModel):
    prompt: str = Field(
        min_length=1,
        max_length=4_000,
        description="Image prompt sent to the local FLUX orchestrator.",
    )
    width: int = Field(default=1280, ge=256, le=1920, multiple_of=8)
    height: int = Field(default=720, ge=256, le=1920, multiple_of=8)

    @model_validator(mode="after")
    def validate_pixel_budget(self) -> "FluxImageRequest":
        if self.width * self.height > 2_500_000:
            raise ValueError("image exceeds the 2.5 megapixel limit")
        return self


class StateFilter(str, Enum):
    open = "open"
    closed = "closed"
    all = "all"


IssueState = Literal["open", "closed", "all"]

