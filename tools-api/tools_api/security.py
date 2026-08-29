"""Authentication dependency for all tool endpoints."""

from __future__ import annotations

import secrets
from typing import Annotated

from fastapi import HTTPException, Request, Security, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer


bearer_scheme = HTTPBearer(
    auto_error=False,
    scheme_name="InternalBearer",
    description="Internal bearer token shared only with Open WebUI.",
)


async def require_internal_bearer(
    request: Request,
    credentials: Annotated[
        HTTPAuthorizationCredentials | None, Security(bearer_scheme)
    ],
) -> None:
    """Fail closed when the internal token is absent or does not match."""

    # FastAPI injects Security dependencies in main.py. Keeping credentials as
    # an explicit argument makes this function straightforward to unit test.
    expected = request.app.state.settings.internal_bearer_token
    if len(expected) < 24:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Internal authentication is not configured",
        )
    if (
        credentials is None
        or credentials.scheme.lower() != "bearer"
        or not secrets.compare_digest(credentials.credentials, expected)
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )
