"""Errors safe to translate into bounded API responses."""

from __future__ import annotations


class ToolsAPIError(Exception):
    """Base class for expected service failures."""

    status_code = 400
    public_message = "Request could not be completed"

    def __init__(self, message: str | None = None) -> None:
        super().__init__(message or self.public_message)
        self.message = message or self.public_message


class ConfigurationError(ToolsAPIError):
    status_code = 503
    public_message = "Required service configuration is unavailable"


class AuthorizationError(ToolsAPIError):
    status_code = 403
    public_message = "Operation is not allowed"


class NotFoundError(ToolsAPIError):
    status_code = 404
    public_message = "Requested resource was not found"


class ConflictError(ToolsAPIError):
    status_code = 409
    public_message = "Requested operation conflicts with existing state"


class PathViolation(ToolsAPIError):
    status_code = 400
    public_message = "Path is outside the permitted repository workspace"


class PayloadTooLarge(ToolsAPIError):
    status_code = 413
    public_message = "Payload exceeds the configured size limit"


class UpstreamError(ToolsAPIError):
    status_code = 502
    public_message = "An internal upstream service failed"


class UpstreamTimeout(ToolsAPIError):
    status_code = 504
    public_message = "An internal upstream service timed out"


class CommandUnavailable(ConfigurationError):
    public_message = "Required command is not installed"


class CommandFailed(UpstreamError):
    """A fixed subprocess returned a non-zero status."""

    def __init__(self, returncode: int, stderr: str = "") -> None:
        detail = stderr.strip()[:2000]
        message = f"Command failed with status {returncode}"
        if detail:
            message = f"{message}: {detail}"
        super().__init__(message)
        self.returncode = returncode


class CommandTimedOut(UpstreamTimeout):
    public_message = "Command exceeded its time limit"


class CommandOutputTooLarge(UpstreamError):
    public_message = "Command output exceeded its size limit"

