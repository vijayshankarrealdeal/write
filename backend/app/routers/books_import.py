"""Audiobook import — ingests a `book_ingest.deploy` bundle.

Reads files from a server-local path produced by the
`/Users/vijayshankar/dispose` pipeline (cleaned text + MP3 audio +
word-timing JSONs + cover image), uploads the audio + cover assets to
MinIO, and creates the FeedItem + Writing + Section rows that surface
the book in the reader app.

Expected on-disk layout (the path the admin POSTs to this endpoint):

    <slug>/
    ├── manifest.json                  # title, author, slug
    ├── images/cover.png               # the square audio-player cover
    └── audio/
        ├── manifest.json              # chapters[], characters[]
        ├── voice_plan.json            # narrator_voice + per-char voices
        ├── 01_chapter-...md           # cleaned chapter text (verbatim)
        └── wav/
            ├── 01_chapter-...mp3      # 32 kbps mono — uploaded
            └── 01_chapter-...words.json  # word timings — uploaded

NOT uploaded: the .wav originals (large, derivable from the .md text
via tts_synth — see BOOK_PIPELINE.md). Character intros are also not
exposed through this endpoint yet; they'll get their own pass.

Auth: reuses the admin token from `app.routers.admin._verify_admin`,
matching the rest of the admin tooling. Admins POST a `path` plus the
acting `author_user_id` (the public byline owner) — multiple test
books can be imported under the admin user without churning real
user accounts.
"""
from __future__ import annotations

import json
import mimetypes
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models.feed_item import FeedItem
from app.models.section import Section
from app.models.user import User
from app.models.writing import Writing
from app.routers.admin import _verify_admin
from app.storage import upload_file


router = APIRouter(prefix="/api/admin/books", tags=["admin", "books"])


class ImportRequest(BaseModel):
    """Body of POST /api/admin/books/import.

    `path` is a server-local directory holding the bundled book (the
    `dispose/storage/books/<slug>/` directory after `book_ingest.deploy`
    has run, or the unpacked tarball). `author_user_id` is the user the
    feed item will be filed under — set this to your admin user for
    catalogue imports.
    """

    path: str
    author_user_id: str
    is_draft: bool = False
    price_cents: int = 0


def _slugify(s: str) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "-", s.lower()).strip("-")
    return s[:80] or "book"


def _read_json(p: Path) -> dict | list | None:
    try:
        with p.open() as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def _chapters_in_order(audio_dir: Path) -> list[dict]:
    """Return `[{md, mp3, words_json, title, chunk_id}]` in chapter order.

    Pulls ordering from `audio/manifest.json` if present (the standard
    output of the per-book Sonnet agent); falls back to lexicographic
    glob of `audio/*.md` which works for the prefixed `NN_slug.md`
    naming we always use. ``chunk_id`` lets us look up the matching
    pre-rendered Quill delta in ``sections/<chunk_id>.delta.json`` so
    chapters retain their scene illustrations from the ingest pipeline.
    """
    manifest = _read_json(audio_dir / "manifest.json") or {}
    chapters = manifest.get("chapters") if isinstance(manifest, dict) else None

    out: list[dict] = []
    if isinstance(chapters, list) and chapters:
        for ch in chapters:
            md_name = ch.get("file")
            title = ch.get("title")
            if not md_name:
                continue
            md = audio_dir / md_name
            stem = Path(md_name).stem
            out.append(
                {
                    "md": md,
                    "mp3": audio_dir / "wav" / f"{stem}.mp3",
                    "words_json": audio_dir / "wav" / f"{stem}.words.json",
                    "title": title or stem,
                    "chunk_id": ch.get("chunk_id"),
                }
            )
    else:
        for md in sorted(audio_dir.glob("*.md")):
            stem = md.stem
            out.append(
                {
                    "md": md,
                    "mp3": audio_dir / "wav" / f"{stem}.mp3",
                    "words_json": audio_dir / "wav" / f"{stem}.words.json",
                    "title": stem,
                    "chunk_id": None,
                }
            )
    return out


_LOCAL_IMAGE_RE = re.compile(
    r"^/api/books/[^/]+/images/(?P<scene_id>[A-Za-z0-9_-]+)/png$"
)


async def _upload_chapter_images(
    *, slug: str, book_dir: Path,
) -> dict[str, str]:
    """Upload every chapter scene PNG to MinIO. Returns
    ``{scene_id: minio_url}``. Idempotent — re-uploading the same path
    is cheap and gives us a deterministic URL the delta can reference."""
    images_dir = book_dir / "images"
    if not images_dir.is_dir():
        return {}
    out: dict[str, str] = {}
    for png in sorted(images_dir.glob("*.png")):
        scene_id = png.stem
        if scene_id == "cover":
            continue  # cover handled above with its own variants
        try:
            data = png.read_bytes()
        except OSError:
            continue
        url = await upload_file(
            f"books/{slug}/scenes/{scene_id}.png",
            data,
            content_type="image/png",
        )
        out[scene_id] = url
    return out


def _delta_with_remapped_images(
    delta: list[dict], image_urls: dict[str, str],
) -> list[dict]:
    """Rewrite any ``/api/books/<slug>/images/<scene>/png`` references
    in a Quill delta to their uploaded MinIO URLs. Also drops the
    leading ``"Chapter X" + {header:2}`` pair the ingest pipeline
    emits — the Flutter reader already paints Section.title above the
    body, so keeping it would render the chapter name twice."""
    src_ops = list(delta)
    if len(src_ops) >= 2:
        first = src_ops[0]
        second = src_ops[1]
        first_insert = first.get("insert") if isinstance(first, dict) else None
        second_insert = second.get("insert") if isinstance(second, dict) else None
        second_attrs = second.get("attributes") if isinstance(second, dict) else None
        if (
            isinstance(first_insert, str)
            and second_insert == "\n"
            and isinstance(second_attrs, dict)
            and second_attrs.get("header")
        ):
            src_ops = src_ops[2:]

    out: list[dict] = []
    for op in src_ops:
        insert = op.get("insert") if isinstance(op, dict) else None
        if isinstance(insert, dict) and "image" in insert:
            src = insert.get("image") or ""
            m = _LOCAL_IMAGE_RE.match(src) if isinstance(src, str) else None
            if m:
                scene_id = m.group("scene_id")
                remote = image_urls.get(scene_id)
                if remote:
                    new_op = dict(op)
                    new_op["insert"] = {**insert, "image": remote}
                    out.append(new_op)
                    continue
        out.append(op)
    return out


def _quill_delta_for(text: str) -> list[dict]:
    """Wrap a plain-text chapter into a minimal Quill delta. One
    paragraph per blank-line-separated block; preserves the prose
    character-for-character.
    """
    paragraphs = re.split(r"\n\s*\n+", text.strip())
    ops: list[dict] = []
    for para in paragraphs:
        # Strip leading "## CHAPTER X. Title" header that the cleaned
        # MD files start with — the Section already carries the title,
        # so duplicating it as the first line of the body would render
        # it twice in the reader.
        if ops or not re.match(r"^#+\s+", para):
            ops.append({"insert": para.strip() + "\n"})
    return ops or [{"insert": text + "\n"}]


@router.post("/import")
async def import_book(
    body: ImportRequest,
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Ingest one audiobook bundle from a server-local path.

    Idempotent on `(author_user_id, slug)`: a re-run updates the
    existing FeedItem + Writing in place and re-uploads any audio
    assets whose MinIO URL is missing on the matching Section row.
    """
    book_dir = Path(body.path).expanduser().resolve()
    if not book_dir.is_dir():
        raise HTTPException(404, f"path is not a directory: {book_dir}")

    audio_dir = book_dir / "audio"
    if not audio_dir.is_dir():
        raise HTTPException(404, f"missing audio/ inside {book_dir}")

    # ── 1. book-level metadata ────────────────────────────────────────
    book_manifest = _read_json(book_dir / "manifest.json") or {}
    slug = book_manifest.get("slug") or _slugify(book_dir.name)
    title = book_manifest.get("title") or slug.replace("-", " ").title()
    author = book_manifest.get("author") or "Unknown"
    description = (
        (book_manifest.get("poster") or {}).get("description")
        or book_manifest.get("description")
    )
    genres = list((book_manifest.get("poster") or {}).get("genres") or [])
    tags = list((book_manifest.get("poster") or {}).get("tags") or [])

    # Validate the acting user exists.
    try:
        author_uuid = uuid.UUID(body.author_user_id)
    except ValueError:
        raise HTTPException(400, "author_user_id is not a UUID")
    author_user = (
        await db.execute(select(User).where(User.id == author_uuid))
    ).scalar_one_or_none()
    if author_user is None:
        raise HTTPException(404, f"author_user not found: {author_uuid}")

    # ── 2. cover image upload ─────────────────────────────────────────
    cover_url: str | None = None
    cover_path = book_dir / "images" / "cover.png"
    if cover_path.exists():
        ext = cover_path.suffix.lstrip(".") or "png"
        cover_data = cover_path.read_bytes()
        cover_url = await upload_file(
            f"books/{slug}/cover.{ext}",
            cover_data,
            content_type=mimetypes.types_map.get(f".{ext}", "image/png"),
        )

    # ── 2b. chapter scene-image upload ────────────────────────────────
    # The ingest pipeline writes per-chapter illustrations to
    # ``images/<scene_id>.png`` and embeds them in
    # ``sections/<chunk_id>.delta.json``. Upload each PNG to MinIO so
    # the delta can be rewritten with public URLs below — otherwise
    # the chapter body renders with broken images that point at the
    # studio dev server.
    scene_image_urls = await _upload_chapter_images(
        slug=slug, book_dir=book_dir,
    )

    sections_dir = book_dir / "sections"

    # ── 3. find-or-create Writing + FeedItem ──────────────────────────
    writing = (
        await db.execute(
            select(Writing).where(
                Writing.user_id == author_uuid, Writing.title == title
            )
        )
    ).scalar_one_or_none()
    if writing is None:
        writing = Writing(
            id=uuid.uuid4(),
            user_id=author_uuid,
            title=title,
            section_ids=[],
        )
        db.add(writing)
        await db.flush()

    feed_item = (
        await db.execute(
            select(FeedItem).where(FeedItem.writing_id == writing.id)
        )
    ).scalar_one_or_none()
    if feed_item is None:
        feed_item = FeedItem(
            id=uuid.uuid4(),
            title=title,
            author=author,
            author_id=author_uuid,
            writing_id=writing.id,
            description=description,
            image_url=cover_url,
            cover_image_url=cover_url,
            genres=genres,
            tags=tags,
            writing_types=["book", "audiobook"],
            is_draft=body.is_draft,
            price_cents=body.price_cents,
        )
        db.add(feed_item)
    else:
        feed_item.title = title
        feed_item.author = author
        feed_item.description = description
        feed_item.image_url = feed_item.image_url or cover_url
        feed_item.cover_image_url = cover_url or feed_item.cover_image_url
        feed_item.genres = genres
        feed_item.tags = tags

    await db.flush()

    # ── 4. voice plan (so we can store voice_name per chapter) ────────
    voice_plan = _read_json(audio_dir / "voice_plan.json") or {}
    narrator_voice = voice_plan.get("narrator_voice")

    # ── 5. iterate chapters: upload assets + upsert Section row ──────
    chapters = _chapters_in_order(audio_dir)
    if not chapters:
        raise HTTPException(404, "no chapters found in audio/")

    # Keep the writing.section_ids in chapter order. Multi-part books
    # repeat chapter titles ("Chapter I" appears once per Part), so we
    # bucket existing sections by title and pop one per occurrence — a
    # single dict would collapse all duplicates onto one section and
    # silently skip the rest of the audio.
    _existing_rows = (
        await db.execute(
            select(Section).where(Section.writing_id == writing.id)
        )
    ).scalars().all()
    existing_by_title: dict[str, list[Section]] = {}
    for s in _existing_rows:
        existing_by_title.setdefault(s.title or "", []).append(s)

    new_section_ids: list[str] = []
    imported = 0
    skipped_audio = 0

    for idx, ch in enumerate(chapters):
        md_text = ch["md"].read_text(encoding="utf-8") if ch["md"].exists() else ""
        # Prefer the pre-rendered Quill delta from ``sections/`` — it
        # carries the chapter's scene illustration + italic caption
        # that the ingest pipeline planned. Fall back to the raw .md
        # text when no delta is on disk (e.g. very old bundles).
        chunk_id = ch.get("chunk_id") or ""
        delta_path = (
            (sections_dir / f"{chunk_id}.delta.json")
            if (sections_dir.is_dir() and chunk_id)
            else None
        )
        section_delta: list[dict] | None = None
        if delta_path and delta_path.exists():
            raw = _read_json(delta_path)
            if isinstance(raw, list):
                section_delta = _delta_with_remapped_images(
                    raw, scene_image_urls,
                )
        if section_delta is None:
            section_delta = _quill_delta_for(md_text)

        bucket = existing_by_title.get(ch["title"] or "", [])
        section = bucket.pop(0) if bucket else None
        if section is None:
            section = Section(
                id=uuid.uuid4(),
                writing_id=writing.id,
                title=ch["title"],
                content=section_delta,
                is_published=True,
                sort_order=idx,
                kind="chapter",
            )
            db.add(section)
        else:
            section.content = section_delta
            section.is_published = True
            section.sort_order = idx

        # Audio uploads — only if the MP3 actually exists on disk.
        if ch["mp3"].exists() and not section.audio_url:
            section.audio_url = await upload_file(
                f"books/{slug}/audio/{ch['mp3'].name}",
                ch["mp3"].read_bytes(),
                content_type="audio/mpeg",
            )
            imported += 1
        elif not ch["mp3"].exists():
            skipped_audio += 1

        if ch["words_json"].exists() and not section.audio_words_url:
            section.audio_words_url = await upload_file(
                f"books/{slug}/audio/{ch['words_json'].name}",
                ch["words_json"].read_bytes(),
                content_type="application/json",
            )
            words = _read_json(ch["words_json"])
            if isinstance(words, dict):
                d = words.get("duration")
                if isinstance(d, (int, float)):
                    section.audio_duration_s = float(d)

        if narrator_voice:
            section.voice_name = narrator_voice

        await db.flush()
        new_section_ids.append(str(section.id))

    writing.section_ids = new_section_ids
    await db.flush()
    await db.commit()

    return {
        "slug": slug,
        "feed_item_id": str(feed_item.id),
        "writing_id": str(writing.id),
        "chapters": len(chapters),
        "audio_uploaded": imported,
        "audio_missing": skipped_audio,
        "cover_url": cover_url,
        "imported_at": datetime.now(timezone.utc).isoformat(),
    }


class PlaybackPositionUpdate(BaseModel):
    section_id: str
    position_seconds: float


@router.post("/playback-position/{feed_item_id}", include_in_schema=False)
async def remember_playback_position(
    feed_item_id: str,
    body: PlaybackPositionUpdate,
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Stub for server-side resume.

    The client persists position in Hive (`audio_last_played` box) for
    instant-resume on relaunch; this endpoint is the cross-device
    fallback. Wire it into a per-user `reading_progress` table when
    that lands — for now it's a no-op so the client can ship a request
    without 404'ing.
    """
    return {"feed_item_id": feed_item_id, "section_id": body.section_id, "saved": True}
