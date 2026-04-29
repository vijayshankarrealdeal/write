"""Phase 5 — generate illustrations via Azure gpt-image-2.

Lifted from test.ipynb but cleaned up: API key from env (not hardcoded),
retry on 5xx, runs in a thread so asyncio orchestration stays simple.

Reader-preference plumbing: every scene prompt is composed as

    <scene description>. <book-wide style>. <reader_preference>. <negative>

so the *user's* taste (e.g. "I like mystical, painterly imagery") steers
the result alongside the per-book style. Empty preference → no-op.
"""

from __future__ import annotations

import asyncio
import base64
import os
import time

import requests

from .config import config


_NEGATIVE_GUIDANCE = "no text, no captions, no logos, no watermark"


def compose_prompt(
    scene: str,
    *,
    style: str | None,
    reader_preference: str | None,
) -> str:
    parts = [scene.strip().rstrip(".")]
    if style:
        parts.append(style.strip().rstrip("."))
    if reader_preference:
        parts.append(f"reader preference: {reader_preference.strip().rstrip('.')}")
    parts.append(_NEGATIVE_GUIDANCE)
    return ". ".join(parts)


def generate_image_sync(
    prompt: str,
    out_path: str,
    *,
    style: str | None = None,
    reader_preference: str | None = None,
    size: str = "1024x1024",
    quality: str = "low",
    retries: int = 2,
) -> str:
    url = (
        f"{config.image_endpoint}/openai/deployments/{config.image_deployment}"
        f"/images/generations?api-version={config.image_api_version}"
    )
    body = {
        "prompt": compose_prompt(prompt, style=style, reader_preference=reader_preference),
        "size": size,
        "quality": quality,
        "output_compression": 100,
        "output_format": "png",
        "n": 1,
    }
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {config.image_api_key}",
    }

    last_exc: Exception | None = None
    for attempt in range(retries + 1):
        try:
            r = requests.post(url, headers=headers, json=body, timeout=120)
            r.raise_for_status()
            b64 = r.json()["data"][0]["b64_json"]
            os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
            with open(out_path, "wb") as f:
                f.write(base64.b64decode(b64))
            return out_path
        except requests.HTTPError as exc:
            last_exc = exc
            status = exc.response.status_code if exc.response is not None else 0
            if status < 500 or attempt == retries:
                raise
            time.sleep(1.5 * (attempt + 1))
        except requests.RequestException as exc:
            last_exc = exc
            if attempt == retries:
                raise
            time.sleep(1.5 * (attempt + 1))

    assert last_exc is not None
    raise last_exc


async def generate_image(
    prompt: str,
    out_path: str,
    *,
    style: str | None = None,
    reader_preference: str | None = None,
) -> str:
    return await asyncio.to_thread(
        generate_image_sync,
        prompt,
        out_path,
        style=style,
        reader_preference=reader_preference,
    )
