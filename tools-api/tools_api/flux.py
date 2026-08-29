"""Bounded proxy to the private GPU image orchestration service."""

from __future__ import annotations

from dataclasses import dataclass
import json
from typing import Any

import httpx

from .config import Settings
from .errors import ConfigurationError, PayloadTooLarge, UpstreamError, UpstreamTimeout
from .models import FluxImageRequest


@dataclass(frozen=True, slots=True)
class FluxResult:
    """Validated response from the image orchestrator."""

    content: bytes | dict[str, Any]
    media_type: str


class FluxClient:
    """Call only the configured orchestration URL with internal bearer auth."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    def generate(self, request: FluxImageRequest) -> FluxResult:
        """Request a 720p-by-default image from the local GPU orchestrator."""

        if not self.settings.flux_orchestrator_token:
            raise ConfigurationError("FLUX orchestrator authentication is not configured")
        headers = {
            "Authorization": f"Bearer {self.settings.flux_orchestrator_token}",
            "Accept": "image/png, application/json",
        }
        timeout = httpx.Timeout(
            connect=5.0,
            read=float(self.settings.flux_timeout_seconds),
            write=30.0,
            pool=5.0,
        )
        try:
            with httpx.Client(timeout=timeout, follow_redirects=False) as client:
                with client.stream(
                    "POST",
                    self.settings.flux_orchestrator_url,
                    headers=headers,
                    json=request.model_dump(),
                ) as response:
                    media_type = response.headers.get("content-type", "").split(";", 1)[0]
                    limit = (
                        self.settings.max_flux_response_bytes
                        if media_type == "image/png"
                        else min(self.settings.max_flux_response_bytes, 1024 * 1024)
                    )
                    body = bytearray()
                    for chunk in response.iter_bytes():
                        body.extend(chunk)
                        if len(body) > limit:
                            raise PayloadTooLarge("FLUX response exceeds its size limit")
                    if not 200 <= response.status_code < 300:
                        raise UpstreamError(
                            f"FLUX orchestrator returned status {response.status_code}"
                        )
        except httpx.TimeoutException as exc:
            raise UpstreamTimeout("FLUX orchestrator timed out") from exc
        except httpx.HTTPError as exc:
            raise UpstreamError("FLUX orchestrator could not be reached") from exc

        if media_type == "image/png":
            if not body.startswith(b"\x89PNG\r\n\x1a\n"):
                raise UpstreamError("FLUX orchestrator returned an invalid PNG")
            return FluxResult(content=bytes(body), media_type="image/png")
        if media_type in {"application/json", "application/problem+json"}:
            try:
                payload = json.loads(body)
            except json.JSONDecodeError as exc:
                raise UpstreamError("FLUX orchestrator returned invalid JSON") from exc
            if not isinstance(payload, dict):
                raise UpstreamError("FLUX orchestrator returned an unexpected response")
            return FluxResult(content=payload, media_type="application/json")
        raise UpstreamError("FLUX orchestrator returned an unsupported content type")

