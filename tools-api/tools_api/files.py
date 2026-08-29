"""Filesystem jail helpers for repositories and diagnostic file access."""

from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import stat
import tempfile
from typing import Any

from .config import Settings, normalize_repo_slug
from .errors import AuthorizationError, NotFoundError, PathViolation, PayloadTooLarge


def allowed_repo(settings: Settings, value: str) -> str:
    """Validate a repository slug against the fail-closed allowlist."""

    try:
        slug = normalize_repo_slug(value)
    except ValueError as exc:
        raise PathViolation("Invalid repository identifier") from exc
    if slug not in settings.github_allowed_repos:
        raise AuthorizationError("Repository is not in GITHUB_ALLOWED_REPOS")
    return slug


def canonical_root(settings: Settings) -> Path:
    """Return the canonical repository root without creating it."""

    return settings.repos_root.expanduser().resolve(strict=False)


def repo_path(settings: Settings, slug: str) -> Path:
    """Map an allowlisted slug to ``REPOS_ROOT/owner/repository``."""

    allowed = allowed_repo(settings, slug)
    owner, name = allowed.split("/", 1)
    root = canonical_root(settings)
    candidate = (root / owner / name).resolve(strict=False)
    _require_beneath(root, candidate, allow_root=False)
    _reject_symlink_components(root, root / owner / name)
    return candidate


def require_git_repo(settings: Settings, slug: str) -> Path:
    """Return an allowlisted cloned repository or raise ``NotFoundError``."""

    path = repo_path(settings, slug)
    git_dir = path / ".git"
    if not path.is_dir() or path.is_symlink() or not git_dir.is_dir() or git_dir.is_symlink():
        raise NotFoundError("Repository has not been cloned")
    return path


def _require_beneath(root: Path, candidate: Path, *, allow_root: bool) -> None:
    try:
        relative = candidate.relative_to(root)
    except ValueError as exc:
        raise PathViolation() from exc
    if not allow_root and not relative.parts:
        raise PathViolation("A path below the repository root is required")


def _reject_symlink_components(root: Path, candidate: Path) -> None:
    """Reject every existing symlink below the canonical jail root."""

    try:
        relative = candidate.relative_to(root)
    except ValueError as exc:
        raise PathViolation() from exc
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise PathViolation("Symbolic links are not permitted")


def _block_git_metadata(relative: Path) -> None:
    if any(part.lower() == ".git" for part in relative.parts):
        raise PathViolation("Direct access to Git metadata is not permitted")


def jailed_path(
    root: Path,
    user_path: str,
    *,
    allow_root: bool,
    block_git: bool = True,
) -> Path:
    """Resolve an absolute or relative user path within a canonical root."""

    if not user_path or "\x00" in user_path or "\\" in user_path:
        raise PathViolation("Invalid path")
    raw = Path(user_path)
    unresolved = raw if raw.is_absolute() else root / PurePosixPath(user_path)
    root = root.resolve(strict=False)
    _require_beneath(root, unresolved.resolve(strict=False), allow_root=allow_root)

    # Test both the lexical and resolved path. The former catches an explicit
    # .git segment while the latter catches symlink escapes.
    try:
        lexical_relative = unresolved.relative_to(root)
    except ValueError as exc:
        raise PathViolation() from exc
    if any(part in {"", ".", ".."} for part in PurePosixPath(user_path).parts):
        if ".." in PurePosixPath(user_path).parts:
            raise PathViolation("Parent traversal is not permitted")
    if block_git:
        _block_git_metadata(lexical_relative)
    _reject_symlink_components(root, unresolved)

    candidate = unresolved.resolve(strict=False)
    _require_beneath(root, candidate, allow_root=allow_root)
    if block_git:
        _block_git_metadata(candidate.relative_to(root))
    return candidate


def repo_file_path(settings: Settings, slug: str, user_path: str) -> tuple[Path, Path]:
    """Resolve a file path beneath one cloned, allowlisted repository."""

    root = require_git_repo(settings, slug)
    path = jailed_path(root, user_path, allow_root=False, block_git=True)
    return root, path


def _mkdir_parents_without_symlinks(root: Path, parent: Path) -> None:
    _require_beneath(root, parent, allow_root=True)
    current = root
    for part in parent.relative_to(root).parts:
        current = current / part
        if current.is_symlink():
            raise PathViolation("Symbolic links are not permitted")
        if current.exists() and not current.is_dir():
            raise PathViolation("A path component is not a directory")
        current.mkdir(mode=0o755, exist_ok=True)


def write_utf8_file(
    root: Path,
    target: Path,
    content: str,
    *,
    max_bytes: int,
) -> int:
    """Atomically write bounded UTF-8 text without following symlinks."""

    payload = content.encode("utf-8")
    if len(payload) > max_bytes:
        raise PayloadTooLarge("Text file exceeds MAX_TEXT_FILE_BYTES")
    _require_beneath(root, target, allow_root=False)
    _block_git_metadata(target.relative_to(root))
    _mkdir_parents_without_symlinks(root, target.parent)
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise PathViolation("Target must be a regular file")

    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix=".tools-api-", dir=target.parent, delete=False
        ) as handle:
            temporary_name = handle.name
            os.chmod(temporary_name, 0o600)
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        if target.is_symlink():
            raise PathViolation("Target became a symbolic link")
        os.replace(temporary_name, target)
        temporary_name = None
    finally:
        if temporary_name:
            try:
                Path(temporary_name).unlink()
            except FileNotFoundError:
                pass
    return len(payload)


def read_regular_file(root: Path, target: Path, *, max_bytes: int) -> str:
    """Read a bounded regular file without following its final symlink."""

    _require_beneath(root, target, allow_root=False)
    _reject_symlink_components(root, target)
    if not target.exists():
        raise NotFoundError("File does not exist")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(target, flags)
    except OSError as exc:
        raise PathViolation("File cannot be opened safely") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise PathViolation("Only regular files can be read")
        if metadata.st_size > max_bytes:
            raise PayloadTooLarge("File exceeds MAX_CAT_BYTES")
        payload = os.read(descriptor, max_bytes + 1)
        if len(payload) > max_bytes:
            raise PayloadTooLarge("File exceeds MAX_CAT_BYTES")
    finally:
        os.close(descriptor)
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PathViolation("Only UTF-8 text files can be read") from exc


def list_directory(root: Path, target: Path, *, max_entries: int = 500) -> list[dict[str, Any]]:
    """List a directory without following symlinked entries."""

    _require_beneath(root, target, allow_root=True)
    _reject_symlink_components(root, target)
    if not target.is_dir():
        raise NotFoundError("Directory does not exist")
    entries: list[dict[str, Any]] = []
    for item in sorted(target.iterdir(), key=lambda value: value.name.casefold()):
        if item.name == ".git":
            continue
        metadata = item.lstat()
        entries.append(
            {
                "name": item.name,
                "path": str(item.relative_to(root)),
                "kind": (
                    "symlink"
                    if stat.S_ISLNK(metadata.st_mode)
                    else "directory"
                    if stat.S_ISDIR(metadata.st_mode)
                    else "file"
                    if stat.S_ISREG(metadata.st_mode)
                    else "other"
                ),
                "size": metadata.st_size if stat.S_ISREG(metadata.st_mode) else None,
            }
        )
        if len(entries) >= max_entries:
            break
    return entries

