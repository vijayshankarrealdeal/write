"""Collect + downsize images that should ride along inside an `.inkx`.

Phase 4.2 spec calls for a 1280-px max-edge JPEG at q=80 per image.
The packager today accepts a list of :class:`ImageInput` and ignores
images sourced from MinIO; this module is the bridge that fetches the
bytes (book cover + inline section images), normalises them, and hands
them back as ``ImageInput`` ready for ``pack_book``.

Failure mode: any individual fetch failure is logged and skipped so a
single broken image URL doesn't fail the whole download. The reader
falls back to the blurhash placeholder when an image isn't bundled.
"""

from __future__ import annotations

import asyncio
import io
import json
import re
import uuid as uuid_lib
from typing import Any, Iterable

import blurhash
import httpx
from PIL import Image, ImageOps

from app.logger import get_logger
from app.offline.packager import ImageInput

log = get_logger("app.offline.image_collector")


# 1280 px max edge, JPEG q=80. Matches p2.md §4.2 ("1280px JPEG q80").
MAX_EDGE = 1280
JPEG_QUALITY = 80
HTTP_TIMEOUT_SEC = 8.0
MAX_BYTES_PER_FETCH = 8 * 1024 * 1024  # protects the worker from runaway downloads


def _quill_image_urls(content: Any) -> list[str]:
    """Extract `{insert: {image: "..."}}` URLs from a Quill delta blob.

    Section content can be either a Python list (already decoded) or a
    JSON-encoded string — accept both.
    """
    if not content:
        return []
    if isinstance(content, str):
        try:
            content = json.loads(content)
        except json.JSONDecodeError:
            return []
    if not isinstance(content, list):
        return []
    out: list[str] = []
    for op in content:
        if not isinstance(op, dict):
            continue
        insert = op.get("insert")
        if isinstance(insert, dict):
            url = insert.get("image")
            if isinstance(url, str) and url.startswith(("http://", "https://")):
                out.append(url)
    return out


def _section_inline_image_urls(sections: Iterable[dict[str, Any]]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for s in sections or []:
        content = s.get("content") if isinstance(s, dict) else None
        for url in _quill_image_urls(content):
            if url in seen:
                continue
            seen.add(url)
            out.append(url)
    return out


def _largest_meta_url(image_url: str | None, image_meta: dict | None) -> str | None:
    """Pick the URL that best fits the offline package.

    Prefer the `medium` variant from image_meta (≤800px) — close to the
    1280-cap target, smaller fetch. Fall back to the legacy single URL
    when meta isn't present.
    """
    if image_meta and isinstance(image_meta, dict):
        base = image_meta.get("base_url")
        variants = image_meta.get("variants") or {}
        formats = image_meta.get("formats") or ["webp"]
        fmt = formats[0] if formats else "webp"
        if isinstance(base, str) and base:
            for key in ("medium", "small", "large", "thumb", "original"):
                if key in variants:
                    return f"{base}/{key}.{fmt}"
    return image_url or None


def _process_sync(data: bytes) -> tuple[bytes, str, int, int]:
    """Decode → fix orientation → resize to 1280px max-edge → JPEG q80.

    Returns (jpeg_bytes, blurhash_string, width, height).
    """
    img = Image.open(io.BytesIO(data))
    img = ImageOps.exif_transpose(img)
    img.load()
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")
    w, h = img.size
    longest = max(w, h)
    if longest > MAX_EDGE:
        scale = MAX_EDGE / longest
        img = img.resize(
            (max(1, round(w * scale)), max(1, round(h * scale))),
            Image.Resampling.LANCZOS,
        )
    out_buf = io.BytesIO()
    img.save(out_buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    bhash_input = img.copy()
    longest_bh = max(bhash_input.size)
    if longest_bh > 100:
        s = 100 / longest_bh
        bhash_input = bhash_input.resize(
            (max(1, round(bhash_input.size[0] * s)),
             max(1, round(bhash_input.size[1] * s))),
            Image.Resampling.LANCZOS,
        )
    bhash = blurhash.encode(bhash_input, x_components=4, y_components=3)
    return out_buf.getvalue(), bhash, img.size[0], img.size[1]


async def _fetch(client: httpx.AsyncClient, url: str) -> bytes | None:
    try:
        resp = await client.get(url)
        resp.raise_for_status()
        if len(resp.content) > MAX_BYTES_PER_FETCH:
            log.warning(
                "[offline] skipping oversized image %s (%d bytes)",
                url, len(resp.content),
            )
            return None
        return resp.content
    except (httpx.HTTPError, httpx.InvalidURL) as exc:
        log.warning("[offline] image fetch failed for %s: %s", url, exc)
        return None


def _id_for_url(url: str) -> str:
    return uuid_lib.uuid5(uuid_lib.NAMESPACE_URL, url).hex


_DATA_URL_RE = re.compile(r"^data:")


async def collect_offline_images(
    *,
    cover_url: str | None,
    cover_meta: dict | None,
    sections: list[dict[str, Any]] | None,
) -> list[ImageInput]:
    """Fetch + downscale every image that should ride along inside the
    `.inkx`. Returns a list of [ImageInput] ready to hand to
    [packager.pack_book].

    Designed to be best-effort: a single fetch / decode failure logs
    and is skipped, so a partially-broken book still packs.
    """
    urls: list[str] = []
    cover = _largest_meta_url(cover_url, cover_meta)
    if cover and not _DATA_URL_RE.match(cover):
        urls.append(cover)
    for u in _section_inline_image_urls(sections or []):
        if u != cover:
            urls.append(u)
    if not urls:
        return []

    loop = asyncio.get_running_loop()
    out: list[ImageInput] = []
    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT_SEC, follow_redirects=True) as client:
        # Fetches run in parallel — most servers can handle 4-8 concurrent
        # GETs without spotting it as abuse. We don't pipeline more than
        # the typical book has, so in practice this is small.
        fetches = await asyncio.gather(*(_fetch(client, u) for u in urls))

    for url, raw in zip(urls, fetches):
        if raw is None:
            continue
        try:
            data, bhash, _w, _h = await loop.run_in_executor(None, _process_sync, raw)
        except (Image.UnidentifiedImageError, OSError, ValueError) as exc:
            log.warning("[offline] image decode failed for %s: %s", url, exc)
            continue
        out.append(ImageInput(
            id=_id_for_url(url),
            mime="image/jpeg",
            data=data,
            blurhash=bhash,
        ))
    return out
