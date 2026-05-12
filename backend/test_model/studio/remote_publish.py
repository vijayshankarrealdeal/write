"""Publish a locally-ingested book to a remote inkspacex deployment via
the public REST API.

The old `sync_to_db.py` path requires direct MinIO (port 9000) + Postgres
access on the same machine — fragile, environment-coupled, and useless
when the studio is running somewhere other than the prod box. This
module hits the public REST surface instead:

    POST /api/auth/login                       → access_token
    POST /api/upload/editor                    → image url (with embed meta)
    POST /api/writings/                        → writing
    POST /api/writings/{id}/sections           → section (per chapter)

That's the SAME surface a Flutter or web client uses. No special studio-
only endpoints, no DB credentials in the studio's environment, no MinIO
running locally. Login once, dump everything in parallel.

Concurrency: image uploads + section creates are issued concurrently
under a bounded semaphore (default 8). One book with 50 images and 30
chapters publishes in tens of seconds, not minutes.
"""

from __future__ import annotations

import asyncio
import json
import re
from pathlib import Path
from typing import Any, Awaitable, Callable

import httpx

from book_ingest import cleaner as cleaner_mod
from book_ingest import delta as delta_mod
from book_ingest import persist
from book_ingest.image_planner import PlannedScene
from book_ingest.schemas import ChunkDeep, GeneratedScene


_DEFAULT_API_URL = "https://api.inkspacex.com"
_DEFAULT_PARALLELISM = 8
# Image PNGs from DALL-E are usually 1–3 MB. The /upload/editor route caps
# uploads at 15 MB — well within budget — so streaming isn't necessary.
_UPLOAD_TIMEOUT = httpx.Timeout(60.0, connect=10.0)


class RemotePublishError(RuntimeError):
    """Surface failures with the response body so the studio UI can show
    something more useful than 'request failed'."""

    def __init__(self, message: str, *, status: int | None = None, body: str | None = None):
        super().__init__(message)
        self.status = status
        self.body = body


# ---------------------------------------------------------------------------
# Auth + HTTP client setup
# ---------------------------------------------------------------------------

async def login(api_url: str, email: str, password: str) -> str:
    """Exchange email/password for an access token. The token has a short
    TTL (15 minutes by default) but a single book publish completes well
    inside that window — we don't bother with refresh."""
    url = api_url.rstrip("/") + "/api/auth/login"
    async with httpx.AsyncClient(timeout=20.0) as client:
        r = await client.post(url, json={"email": email, "password": password})
    if r.status_code != 200:
        raise RemotePublishError(
            f"login failed ({r.status_code})",
            status=r.status_code,
            body=r.text[:500],
        )
    body = r.json()
    token = body.get("access_token")
    if not token:
        raise RemotePublishError("login returned no access_token", body=str(body)[:500])
    return token


def _auth_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------------------
# Image upload
# ---------------------------------------------------------------------------

async def upload_image(
    client: httpx.AsyncClient,
    api_url: str,
    token: str,
    *,
    file_path: Path,
    filename: str,
) -> str:
    """POST one PNG to /api/upload/editor and return the URL (already
    includes the embed metadata fragment).

    Thin wrapper over `upload_image_with_meta` that drops the full
    image_meta dict — most callers only persist the URL string (Quill
    embeds, canvas elements), so that's the default. Use
    `upload_image_with_meta` when you also need the variants / blurhash
    structured payload (cover, character portraits)."""
    url, _ = await upload_image_with_meta(
        client, api_url, token, file_path=file_path, filename=filename
    )
    return url


async def upload_image_with_meta(
    client: httpx.AsyncClient,
    api_url: str,
    token: str,
    *,
    file_path: Path,
    filename: str,
) -> tuple[str, dict[str, Any] | None]:
    """POST one PNG to /api/upload/editor and return (url, meta).

    `meta` is the full {base_url, width, height, blurhash, color,
    variants, formats} dict the platform's image pipeline produces.
    Use this for surfaces where the client paints a placeholder
    (blurhash) + picks size variants (covers, character portraits)."""
    url = api_url.rstrip("/") + "/api/upload/editor"
    with open(file_path, "rb") as fh:
        data = fh.read()
    files = {"file": (filename, data, "image/png")}
    r = await client.post(
        url,
        files=files,
        headers=_auth_headers(token),
        timeout=_UPLOAD_TIMEOUT,
    )
    if r.status_code != 200:
        raise RemotePublishError(
            f"upload failed for {filename} ({r.status_code})",
            status=r.status_code,
            body=r.text[:500],
        )
    body = r.json()
    public_url = body.get("url")
    if not public_url:
        raise RemotePublishError(
            f"upload {filename}: response missing url",
            body=str(body)[:500],
        )
    meta = body.get("meta") if isinstance(body, dict) else None
    return public_url, meta if isinstance(meta, dict) else None


async def upload_images_parallel(
    api_url: str,
    token: str,
    *,
    image_paths: dict[str, Path],
    parallelism: int = _DEFAULT_PARALLELISM,
    on_progress: Callable[[int, int], None] | None = None,
) -> dict[str, str]:
    """Upload every image concurrently, capped by `parallelism`. Returns
    {local_path: public_url}. Failures bubble — partial uploads stay
    on the server but the caller decides whether to retry."""
    sem = asyncio.Semaphore(parallelism)
    out: dict[str, str] = {}
    completed = 0
    total = len(image_paths)
    lock = asyncio.Lock()

    async with httpx.AsyncClient(timeout=_UPLOAD_TIMEOUT) as client:

        async def _one(local: str, path: Path) -> None:
            nonlocal completed
            async with sem:
                url = await upload_image(
                    client, api_url, token,
                    file_path=path,
                    filename=path.name,
                )
                async with lock:
                    out[local] = url
                    completed += 1
                    if on_progress:
                        on_progress(completed, total)

        await asyncio.gather(*(_one(k, v) for k, v in image_paths.items()))

    return out


# ---------------------------------------------------------------------------
# Writing + sections
# ---------------------------------------------------------------------------

async def create_writing(
    client: httpx.AsyncClient,
    api_url: str,
    token: str,
    *,
    payload: dict[str, Any],
) -> dict[str, Any]:
    url = api_url.rstrip("/") + "/api/writings/"
    r = await client.post(url, json=payload, headers=_auth_headers(token))
    if r.status_code not in (200, 201):
        raise RemotePublishError(
            f"create_writing failed ({r.status_code})",
            status=r.status_code,
            body=r.text[:500],
        )
    return r.json()


async def create_section(
    client: httpx.AsyncClient,
    api_url: str,
    token: str,
    *,
    writing_id: str,
    payload: dict[str, Any],
) -> dict[str, Any]:
    url = api_url.rstrip("/") + f"/api/writings/{writing_id}/sections"
    r = await client.post(url, json=payload, headers=_auth_headers(token))
    if r.status_code not in (200, 201):
        raise RemotePublishError(
            f"create_section failed ({r.status_code})",
            status=r.status_code,
            body=r.text[:500],
        )
    return r.json()


async def create_feed_item(
    client: httpx.AsyncClient,
    api_url: str,
    token: str,
    *,
    payload: dict[str, Any],
) -> dict[str, Any]:
    """Publishes the writing as a feed card AND flips every listed
    section's `is_published` bit to true in one transaction. Without
    this step, sections stay `is_published=false` and don't show up
    in the reader feed even though the writing exists."""
    url = api_url.rstrip("/") + "/api/feed/"
    r = await client.post(url, json=payload, headers=_auth_headers(token))
    if r.status_code not in (200, 201):
        raise RemotePublishError(
            f"create_feed_item failed ({r.status_code})",
            status=r.status_code,
            body=r.text[:500],
        )
    return r.json()


# ---------------------------------------------------------------------------
# Orchestration — the one entry point the studio calls
# ---------------------------------------------------------------------------

async def publish_book(
    slug: str,
    *,
    api_url: str = _DEFAULT_API_URL,
    email: str,
    password: str,
    on_event: Callable[[str, dict[str, Any]], Awaitable[None] | None] | None = None,
) -> dict[str, Any]:
    """End-to-end publish: login → uploads → writing → sections.

    `on_event(name, payload)` is invoked at major milestones so the
    studio can surface live progress to the UI (login, image-progress,
    writing_created, section-progress, done). Either sync or async.
    """
    async def _emit(name: str, payload: dict[str, Any]) -> None:
        if not on_event:
            return
        result = on_event(name, payload)
        if asyncio.iscoroutine(result):
            await result

    book_dir = persist.book_dir(slug)
    manifest = persist.read_manifest(slug)
    if not manifest:
        raise RemotePublishError(f"manifest missing for {slug}")

    # ---- login ----
    await _emit("login", {"api_url": api_url, "email": email})
    token = await login(api_url, email, password)
    await _emit("logged_in", {"token_prefix": token[:12] + "…"})

    # ---- gather chunks + scenes ----
    chunk_files = sorted((book_dir / "chunks").glob("*.json"))
    if not chunk_files:
        raise RemotePublishError(f"no chunks on disk for {slug}")

    chunks_payload: list[dict[str, Any]] = []
    image_paths: dict[str, Path] = {}
    for path in chunk_files:
        payload = persist._safe_read_json(path)  # type: ignore[attr-defined]
        if not payload:
            continue
        chunks_payload.append(payload)
        scenes = _scenes_for_chunk(book_dir, payload["chunk"]["id"])
        for s in scenes:
            local = s.get("image_path")
            if local and Path(local).exists():
                image_paths[local] = Path(local)

    chunks_payload.sort(
        key=lambda p: (p["chunk"]["page_start"], p["chunk"]["page_end"])
    )

    # Cover image — manifest.cover_image_local is the dedicated jacket
    # image written by the poster phase.
    cover_local = manifest.get("cover_image_local")
    cover_path = Path(cover_local) if cover_local else None
    if cover_path and cover_path.exists():
        image_paths[str(cover_path)] = cover_path

    # ---- upload all images ----
    await _emit("upload_start", {"total": len(image_paths)})

    progress_state = {"done": 0}

    def _img_progress(done: int, total: int) -> None:
        progress_state["done"] = done

    if image_paths:
        url_for_local = await upload_images_parallel(
            api_url, token,
            image_paths=image_paths,
            on_progress=_img_progress,
        )
    else:
        url_for_local = {}
    await _emit("uploads_done", {"count": len(url_for_local)})

    cover_url: str | None = None
    if cover_path and str(cover_path) in url_for_local:
        cover_url = url_for_local[str(cover_path)]

    # ---- create writing ----
    poster = manifest.get("poster") or {}
    writing_payload: dict[str, Any] = {
        "title": manifest.get("title") or slug,
        "description": poster.get("description") or "",
        "cover_image_path": cover_url,
        "status": "published",
        "writing_type": (poster.get("writing_types") or ["book"])[0] if poster.get("writing_types") else "book",
    }
    await _emit("creating_writing", {"title": writing_payload["title"]})

    async with httpx.AsyncClient(timeout=30.0) as client:
        writing = await create_writing(client, api_url, token, payload=writing_payload)
        writing_id = str(writing["id"])
        await _emit("writing_created", {"writing_id": writing_id})

        # ---- create sections (parallel) ----
        await _emit("sections_start", {"total": len(chunks_payload)})
        sem = asyncio.Semaphore(_DEFAULT_PARALLELISM)
        section_done = {"n": 0}
        section_lock = asyncio.Lock()

        async def _make_section(idx: int, payload: dict[str, Any]) -> dict[str, Any]:
            c = payload["chunk"]
            deep_dict = payload.get("deep")
            deep_obj = ChunkDeep.model_validate(deep_dict) if deep_dict else None
            scenes = _scenes_for_chunk(book_dir, c["id"])
            pairs: list[tuple[PlannedScene, GeneratedScene]] = [
                (
                    PlannedScene(
                        scene_id=s["scene_id"],
                        chunk_id=c["id"],
                        chapter_title=s.get("chapter_title"),
                        scene_text=s.get("scene_text", ""),
                        score=float(s.get("score", 0.0)),
                    ),
                    GeneratedScene(
                        scene_id=s["scene_id"],
                        chunk_id=c["id"],
                        prompt=s.get("prompt", ""),
                        image_path=s.get("image_path", ""),
                    ),
                )
                for s in scenes
            ]
            ops = delta_mod.build_section_delta(
                chunk_text=c["text"],
                deep=deep_obj,
                scenes_in_chunk=pairs,
                # Map each local image path to the URL the API gave us
                # back. Falls back to the raw local path so the section
                # still saves (the embed is broken but the prose isn't lost).
                image_url_for=lambda local: url_for_local.get(local, local),
                cleaned_markdown=cleaner_mod.get_cleaned_text(slug, c["id"]),
            )
            section_payload = {
                "title": c.get("chapter_title") or f"Chapter {idx + 1}",
                "content": ops,
            }
            async with sem:
                sec = await create_section(
                    client, api_url, token,
                    writing_id=writing_id,
                    payload=section_payload,
                )
            async with section_lock:
                section_done["n"] += 1
                await _emit("section_progress", {
                    "done": section_done["n"], "total": len(chunks_payload),
                })
            return sec

        sections = await asyncio.gather(
            *(_make_section(i, p) for i, p in enumerate(chunks_payload))
        )

        # ---- upload character portraits ----
        # Each character in the scout's bible got a canonical portrait
        # in storage/<slug>/images/_characters/<safe>.png. Upload each
        # through /api/upload/editor (same path the cover took) so the
        # cast strip on the book detail page has blurhash + variants.
        characters_payload = await _build_remote_characters(
            client, api_url, token, slug=slug, manifest=manifest,
        )
        await _emit("characters_ready", {"count": len(characters_payload)})

        # ---- create feed item + publish all sections ----
        # Sections default to is_published=False on creation. Posting a
        # FeedItem with `published_section_ids = [...all section ids...]`
        # is the API surface that flips them — same path the Flutter
        # editor uses when the author taps "Publish".
        published_ids = [str(s["id"]) for s in sections]
        feed_payload: dict[str, Any] = {
            "title": writing_payload["title"],
            "description": writing_payload.get("description") or "",
            "image_url": cover_url,
            "genres": poster.get("genres") or [],
            "writing_types": poster.get("writing_types") or ["book"],
            "tags": poster.get("tags") or [],
            "is_draft": False,
            "visibility": "public",
            "writing_id": writing_id,
            "published_section_ids": published_ids,
            "characters": characters_payload,
        }
        await _emit("publishing_feed", {"published_count": len(published_ids)})
        try:
            feed_item = await create_feed_item(
                client, api_url, token, payload=feed_payload,
            )
            feed_item_id = feed_item.get("id")
            await _emit("feed_published", {
                "feed_item_id": feed_item_id,
                "published_sections": len(published_ids),
            })
        except RemotePublishError as exc:
            # Sections + writing exist; only the publish step failed.
            # Surface but don't unwind — the user can hit "Publish again"
            # safely (idempotent on writing, re-creates the feed card).
            feed_item_id = None
            await _emit("feed_publish_failed", {
                "message": str(exc),
                "status": exc.status,
                "body": exc.body,
            })

    # ---- mark synced in manifest ----
    manifest["synced_remote"] = {
        "api_url": api_url,
        "writing_id": writing_id,
        "feed_item_id": feed_item_id,
        "n_sections": len(sections),
        "n_images": len(url_for_local),
    }
    persist.write_manifest(slug, manifest)

    await _emit("done", {
        "writing_id": writing_id,
        "feed_item_id": feed_item_id,
        "n_sections": len(sections),
        "n_images": len(url_for_local),
    })
    return {
        "writing_id": writing_id,
        "feed_item_id": feed_item_id,
        "n_sections": len(sections),
        "n_images": len(url_for_local),
        "cover_url": cover_url,
    }


def _scenes_for_chunk(book_dir: Path, chunk_id: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for path in (book_dir / "images").glob("*.json"):
        meta = persist._safe_read_json(path)  # type: ignore[attr-defined]
        if not meta or meta.get("chunk_id") != chunk_id:
            continue
        out.append(meta)
    out.sort(key=lambda m: m.get("score") or 0, reverse=True)
    return out


async def _build_remote_characters(
    client: httpx.AsyncClient,
    api_url: str,
    token: str,
    *,
    slug: str,
    manifest: dict[str, Any],
) -> list[dict[str, Any]]:
    """Upload each character portrait through /api/upload/editor and
    return the per-character publish payload for `POST /api/feed/`.

    Returns [] when the manifest has no character bible (essay
    collections, landscape travelogues). The server treats `[]` as
    "wipe cast" but on a brand-new feed item this is the same as "no
    cast". A None character_sheets dict means the pipeline never
    generated portraits — we still emit the entries with text-only
    appearance descriptions so the cast strip can render initials
    placeholders.
    """
    scout = manifest.get("scout") or {}
    bible = scout.get("character_bible") or []
    if not bible:
        return []
    sheets = manifest.get("character_sheets") or {}

    book = persist.book_dir(slug)
    out: list[dict[str, Any]] = []
    for idx, entry in enumerate(bible):
        if not isinstance(entry, dict):
            continue
        name = (entry.get("name") or "").strip()
        appearance = (entry.get("appearance") or "").strip()
        if not name or not appearance:
            continue
        image_url: str | None = None
        image_meta: dict[str, Any] | None = None
        portrait = _resolve_portrait_path(book, name, sheets.get(name))
        if portrait is not None:
            try:
                image_url, image_meta = await upload_image_with_meta(
                    client, api_url, token,
                    file_path=portrait,
                    filename=portrait.name,
                )
            except RemotePublishError:
                # Portrait upload failed — keep the text-only entry
                # so the cast strip still renders an initials avatar.
                pass
        out.append({
            "name": name,
            "appearance": appearance,
            "bio": (entry.get("bio") or "").strip() or None,
            "image_url": image_url,
            "image_meta": image_meta,
            "sort_order": idx,
        })
    return out


_CHAR_SAFE_NAME_RE = re.compile(r"[^a-z0-9]+")


def _safe_char_slug(name: str) -> str:
    """Mirrors `book_ingest.character_sheets._safe_name` so the portrait
    paths align with the on-disk filenames."""
    return _CHAR_SAFE_NAME_RE.sub("-", name.lower()).strip("-") or "character"


def _resolve_portrait_path(
    book_dir: Path,
    name: str,
    manifest_path: str | None,
) -> Path | None:
    """Find a character's portrait PNG. Tries the conventional
    `images/_characters/<safe>.png` location first because the manifest
    records the absolute path from the machine that generated it, which
    won't exist after a vm-publish copies the storage tree to another
    host."""
    conventional = book_dir / "images" / "_characters" / f"{_safe_char_slug(name)}.png"
    if conventional.exists() and conventional.stat().st_size > 0:
        return conventional
    if manifest_path:
        legacy = Path(manifest_path)
        if legacy.exists() and legacy.stat().st_size > 0:
            return legacy
    return None
