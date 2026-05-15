"""Azure image generation — text-to-image and image-edits (with references).

Hits Azure's REST endpoint directly via httpx (async). Two endpoints:

  • POST /openai/deployments/{d}/images/generations  — text-only
  • POST /openai/deployments/{d}/images/edits        — with reference PNGs

The /edits endpoint anchors character appearance across scenes — same
Alice / Bhīma / Frankenstein in every scene that references her.

Returns raw PNG bytes; caller persists.
"""
from __future__ import annotations

import base64
import json
from pathlib import Path
from typing import Iterable

import httpx

from .config import config
from .retry import with_retries


# ── Content-policy detection ────────────────────────────────────────

_POLICY_KEYWORDS = (
    "content_filter",
    "content_policy",
    "responsiblepolicy",
    "responsible_ai",
    "content management policy",
    "safety system",
    "moderation_blocked",
    "image_generation_user_error",
    "your prompt may contain text",
)


class ContentPolicyViolation(Exception):
    """Azure rejected the prompt for content-policy reasons.

    Surfaced separately from generic 400s so the studio's rephrase-retry
    loop can recognise it and try a softened prompt next, rather than
    retrying the same prompt forever."""

    def __init__(self, message: str, *, body: str = ""):
        super().__init__(message)
        self.body = body


def _is_content_policy_400(status: int, body_text: str) -> bool:
    if status != 400:
        return False
    haystack = body_text.lower()
    return any(k in haystack for k in _POLICY_KEYWORDS)


# ── The actual generation calls ─────────────────────────────────────

def _require_config() -> None:
    if not config.azure_image_endpoint or not config.azure_image_api_key:
        raise RuntimeError(
            "Azure image config missing. Set AZURE_IMAGE_ENDPOINT and "
            "AZURE_IMAGE_API_KEY in .env."
        )


async def _generate_text_only(prompt: str, *, size: str, quality: str) -> bytes:
    _require_config()
    url = (
        f"{config.azure_image_endpoint}/openai/deployments/"
        f"{config.azure_image_deployment}/images/generations"
        f"?api-version={config.azure_image_api_version}"
    )
    payload = {
        "prompt": prompt,
        "size": size,
        "quality": quality,
        "output_format": "png",
        "output_compression": 100,
        "n": 1,
    }
    headers = {
        "Content-Type": "application/json",
        "api-key": config.azure_image_api_key,
        "Authorization": f"Bearer {config.azure_image_api_key}",
    }
    async with httpx.AsyncClient(timeout=180.0) as client:
        r = await client.post(url, headers=headers, json=payload)
    if r.status_code == 400 and _is_content_policy_400(400, r.text):
        raise ContentPolicyViolation(
            f"Azure content policy rejected prompt: {r.text[:200]}",
            body=r.text,
        )
    r.raise_for_status()
    data = r.json()
    b64 = data["data"][0]["b64_json"]
    if not b64:
        raise RuntimeError("Azure returned no image data")
    return base64.b64decode(b64)


async def _generate_with_refs(
    prompt: str, *, size: str, quality: str, refs: list[Path],
) -> bytes:
    _require_config()
    url = (
        f"{config.azure_image_endpoint}/openai/deployments/"
        f"{config.azure_image_deployment}/images/edits"
        f"?api-version={config.azure_image_edits_api_version}"
    )
    headers = {
        "api-key": config.azure_image_api_key,
        "Authorization": f"Bearer {config.azure_image_api_key}",
    }
    data = {
        "prompt": prompt,
        "size": size,
        "quality": quality,
        "n": "1",
        "output_format": "png",
    }
    files: list[tuple[str, tuple[str, bytes, str]]] = []
    for p in refs:
        files.append((
            "image[]",
            (p.name, p.read_bytes(), "image/png"),
        ))
    async with httpx.AsyncClient(timeout=240.0) as client:
        r = await client.post(url, headers=headers, data=data, files=files)
    if r.status_code == 400 and _is_content_policy_400(400, r.text):
        raise ContentPolicyViolation(
            f"Azure content policy rejected prompt: {r.text[:200]}",
            body=r.text,
        )
    r.raise_for_status()
    resp = r.json()
    b64 = resp["data"][0]["b64_json"]
    if not b64:
        raise RuntimeError("Azure returned no image data")
    return base64.b64decode(b64)


async def generate_image(
    prompt: str,
    *,
    size: str = "1024x1536",
    reference_paths: Iterable[str] | None = None,
    quality: str = "medium",
) -> bytes:
    """Generate one PNG. Returns bytes; raises on permanent failure.

    Transient errors (429, 5xx, timeout) retry with backoff. Content-
    policy 400s raise `ContentPolicyViolation` so the studio's rephrase
    loop can softening-retry rather than spinning on the same prompt.
    """
    refs = [Path(p) for p in (reference_paths or []) if Path(p).exists()]

    async def _call() -> bytes:
        if refs:
            return await _generate_with_refs(
                prompt, size=size, quality=quality, refs=refs,
            )
        return await _generate_text_only(prompt, size=size, quality=quality)

    return await with_retries(_call, label="azure-image", max_attempts=3)
