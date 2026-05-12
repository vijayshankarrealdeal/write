"""Optional Phase 7 — push the ingested book into Postgres.

Flow:
  1. Create a random user (random name + email + bcrypt'd random password).
  2. Insert a `Writing` owned by that user with cover image set to the first
     generated illustration.
  3. Insert one `Section` per chunk, with `content` as the Quill Delta from
     `delta.build_section_delta`.
  4. Append section IDs to `Writing.section_ids`.
  5. Pick a random user (could be the new one, could be any existing one)
     and publish the book as a `FeedItem` under that user — this is the
     "select random user to publish" step.

Image src in the Delta uses a file:// URL pointing at the on-disk PNG. If
you later move PNGs to MinIO, swap the `image_url_for` callback in
`pipeline.py` to return the MinIO URL.

This module is intentionally side-effecting — it's the bridge between the
prototype storage layer and the live app database.
"""

from __future__ import annotations

import json
import random
import secrets
import string
import sys
import uuid
from pathlib import Path

# Wire backend so `from app.*` imports resolve.
_BACKEND_ROOT = Path(__file__).resolve().parents[2]
if str(_BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(_BACKEND_ROOT))

from sqlalchemy import select  # noqa: E402
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine  # noqa: E402

from app.config import settings  # noqa: E402
from app.feed_publish import upsert_feed_item_for_writing  # noqa: E402
from app.models.book_character import BookCharacter  # noqa: E402
from app.models.section import Section  # noqa: E402
from app.models.user import User  # noqa: E402
from app.models.writing import Writing  # noqa: E402

from . import cleaner as cleaner_mod  # noqa: E402
from . import delta as delta_mod  # noqa: E402
from .app_taxonomy import (  # noqa: E402
    coerce_writing_type,
    coerce_writing_type_format,
)
from .image_planner import PlannedScene  # noqa: E402
from .schemas import Chunk, ChunkBrief, ChunkDeep, GeneratedScene  # noqa: E402


def _normalize_writing_types(raw: list[str] | None) -> list[str]:
    """Snap whatever the poster (or a hand-edited manifest) emitted onto
    the app's WritingType + format taxonomy. Defends against legacy
    manifests where writing_types[0] was 'sacred-text' or 'epic'."""
    wt_raw = raw[0] if raw else None
    fmt_raw = raw[1] if raw and len(raw) > 1 else None
    wt = coerce_writing_type(wt_raw)
    fmt = coerce_writing_type_format(wt, fmt_raw)
    return [wt, fmt]


# Canonical editorial identity used by every batch-ingested book. Sharing
# the constants here means the CLIs (ingest_book.py / sync_to_db.py /
# batch_ingest.py) all upload under the same loginnable account, and the
# password is the one you'd use from the app or from curl to verify the
# upload landed.
INKSPACE_EMAIL = "inkspace@inkspacex.com"
INKSPACE_NAME = "inkspace"
INKSPACE_PASSWORD = "Google@99"


_FIRST_NAMES = [
    "Aanya", "Rohan", "Maya", "Arjun", "Iris", "Noor", "Kai", "Lena",
    "Felix", "Priya", "Theo", "Zara", "Soren", "Anya", "Mateo", "Ines",
]
_LAST_NAMES = [
    "Storm", "Vale", "Quill", "Hart", "Reyes", "Okoye", "Marsh", "Solis",
    "Ito", "Bourne", "Carmine", "Nash", "Avery", "Bloom", "Kade", "Lark",
]


def _random_name() -> str:
    return f"{random.choice(_FIRST_NAMES)} {random.choice(_LAST_NAMES)}"


def _random_email(name: str) -> str:
    handle = name.lower().replace(" ", ".")
    suffix = "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
    return f"{handle}.{suffix}@inkx.local"


def _random_password_hash() -> str:
    """Returns a bcrypt-style hash placeholder. The user is never expected
    to log in — they exist purely as an authoring identity."""
    # passlib import is heavy; a plain marker is fine since the column is
    # nullable Text and these accounts can't authenticate anyway.
    return "!ingest-only-" + secrets.token_urlsafe(16)


def _make_engine():
    return create_async_engine(settings.database_url, future=True)


async def publish_book(
    *,
    title: str,
    author: str | None,
    description: str | None,
    cover_image_path: str | None,
    cover_image_meta: dict | None = None,
    chunks: list[Chunk],
    briefs: dict[str, ChunkBrief],
    deeps: dict[str, ChunkDeep],
    scenes_by_chunk: dict[str, list[tuple[PlannedScene, GeneratedScene]]],
    image_url_for,
    use_existing_user_for_publish: bool = True,
    primary_account_email: str | None = None,
    primary_account_name: str | None = None,
    primary_account_password: str | None = None,
    primary_account_avatar_url: str | None = None,
    genres: list[str] | None = None,
    writing_types: list[str] | None = None,
    tags: list[str] | None = None,
    cleaned_markdown: dict[str, str] | None = None,
    visibility: str = "public",
    characters: list[dict] | None = None,
) -> dict[str, str]:
    """Persist Writing + Sections.

    Two modes:

    - **primary_account_email set**: idempotent. Find-or-create one
      well-known user (the "InkSpaceX Editorial" identity), publish the
      book under it as both author and FeedItem publisher. Re-running
      against the same email reuses the user.
    - **email unset (default)**: create a random author user, pick a
      random publisher — useful for seeding test data.

    Returns {"author_user_id", "writing_id", "feed_item_id", "publisher_user_id"}.
    """
    engine = _make_engine()
    Session = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)

    async with Session() as db:
        if primary_account_email:
            author_user = await _find_or_create_primary_user(
                db,
                email=primary_account_email,
                name=primary_account_name or "InkSpaceX",
                password=primary_account_password,
                avatar_url=primary_account_avatar_url,
            )
        else:
            author_user = await _create_random_user(db, display_name=author)
        normalized_types = _normalize_writing_types(writing_types)
        writing = await _insert_writing(
            db,
            user_id=author_user.id,
            title=title,
            author=author or author_user.name,
            description=description,
            cover_image_path=cover_image_path,
            cover_image_meta=cover_image_meta,
            writing_type=normalized_types[0],
            subtype=normalized_types[1] or None,
        )
        section_rows: list[Section] = []
        for idx, chunk in enumerate(chunks, start=1):
            cleaned_md = cleaned_markdown.get(chunk.id) if cleaned_markdown else None
            ops = delta_mod.build_section_delta(
                chunk_text=chunk.text,
                deep=deeps.get(chunk.id),
                scenes_in_chunk=scenes_by_chunk.get(chunk.id, []),
                image_url_for=image_url_for,
                cleaned_markdown=cleaned_md,
            )
            # Title precedence: detected chapter heading → 'Chapter N' fallback.
            # We avoid 'Pages X-Y' fallbacks because they expose the PDF's
            # internal page boundaries to readers, which is meaningless.
            title = chunk.chapter_title or f"Chapter {idx}"
            # Ingested books publish every chapter by default — the
            # author here is the InkSpace editorial identity, and the
            # whole book is meant to be public on ingest. (Author-driven
            # publishes from the Flutter editor flip these per-section
            # via the publish-dialog ticks.)
            section = Section(
                writing_id=writing.id,
                title=title,
                content=ops,
                section_color=None,
                is_published=True,
            )
            db.add(section)
            section_rows.append(section)
        await db.flush()

        writing.section_ids = [str(s.id) for s in section_rows]
        await db.flush()

        # Cast strip: one row per character the scout proposed. The
        # writing's cascade-delete owns these — when the Writing is
        # deleted (re-publish path) the cast goes with it. Books
        # without a bible (essay collections, landscape travelogues)
        # simply get zero rows here, and the client hides the strip.
        if characters:
            for entry in characters:
                name = (entry.get("name") or "").strip()
                appearance = (entry.get("appearance") or "").strip()
                if not name or not appearance:
                    continue
                db.add(BookCharacter(
                    writing_id=writing.id,
                    name=name,
                    appearance=appearance,
                    bio=(entry.get("bio") or "").strip() or None,
                    image_url=entry.get("image_url"),
                    image_meta=entry.get("image_meta"),
                    sort_order=int(entry.get("sort_order") or 0),
                ))
            await db.flush()

        if primary_account_email:
            # Primary-account mode: same identity authors AND publishes,
            # so the FeedItem shows the InkSpaceX name in the feed.
            publisher = author_user
        else:
            publisher = await _pick_publisher(db, fallback=author_user, prefer_existing=use_existing_user_for_publish)
        # The ingest path uploads the book (Writing + Sections); the
        # feed-card projection is owned by `app.feed_publish` so the
        # ingest pipeline, the public POST /api/feed/ route, and any
        # future caller share one path — and so every card carries the
        # writing_id FK that drives ON DELETE CASCADE.
        # Section bodies stay in the `sections` table only — readers
        # fetch them lazily via /api/feed/{id}/sections/{section_id}.
        # No JSONB snapshot to keep in sync.
        feed_item = await upsert_feed_item_for_writing(
            db,
            writing_id=writing.id,
            publisher=publisher,
            title=writing.title,
            description=writing.description,
            image_url=writing.cover_image_path,
            image_meta=cover_image_meta,
            genres=genres,
            writing_types=normalized_types,
            tags=tags,
            is_draft=False,
            visibility=visibility,
            # Byline shows the book's real author (e.g. "Jane Austen"),
            # not the editorial publishing identity ("inkspace") used as
            # the FeedItem.author_id. UI surfaces "Presented by inkspace"
            # below the byline so the publisher is still credited.
            author_display=writing.author,
        )

        return {
            "author_user_id": str(author_user.id),
            "writing_id": str(writing.id),
            "feed_item_id": str(feed_item.id),
            "publisher_user_id": str(publisher.id),
        }


async def _find_or_create_primary_user(
    db: AsyncSession,
    *,
    email: str,
    name: str,
    password: str | None = None,
    avatar_url: str | None = None,
) -> User:
    """Idempotent: returns the existing user with this email, or creates one.
    Used for the platform's editorial publishing identity (e.g.
    inkspace@inkspacex.com). When `password` is provided, hashes it with
    bcrypt so the account is loginnable. When `avatar_url` is provided,
    sets it as the user's photo_url (a public MinIO URL)."""
    pw_hash = _hash_password(password) if password else _random_password_hash()

    existing = (await db.execute(select(User).where(User.email == email))).scalar_one_or_none()
    if existing is not None:
        changed = False
        if name and existing.name != name:
            existing.name = name; changed = True
        if password:  # always reset to the requested password if one was given
            existing.password_hash = pw_hash; changed = True
        if avatar_url and existing.photo_url != avatar_url:
            existing.photo_url = avatar_url; changed = True
        if changed:
            await db.flush()
        return existing
    user = User(
        email=email,
        name=name,
        password_hash=pw_hash,
        photo_url=avatar_url,
        onboarding_complete=True,
    )
    db.add(user)
    await db.flush()
    return user


def _hash_password(plain: str) -> str:
    """bcrypt hash, matching what the auth router uses on registration."""
    from passlib.context import CryptContext
    ctx = CryptContext(schemes=["bcrypt"], deprecated="auto")
    return ctx.hash(plain)


async def _create_random_user(db: AsyncSession, *, display_name: str | None) -> User:
    name = display_name or _random_name()
    email = _random_email(name)
    user = User(
        email=email,
        name=name,
        password_hash=_random_password_hash(),
        onboarding_complete=True,
    )
    db.add(user)
    await db.flush()
    return user


async def _insert_writing(
    db: AsyncSession,
    *,
    user_id: uuid.UUID,
    title: str,
    author: str | None,
    description: str | None,
    cover_image_path: str | None,
    cover_image_meta: dict | None = None,
    writing_type: str = "book",
    subtype: str | None = None,
) -> Writing:
    writing = Writing(
        user_id=user_id,
        title=title,
        author=author,
        description=description,
        cover_image_path=cover_image_path,
        cover_image_meta=cover_image_meta,
        status="published",
        writing_type=writing_type,
        subtype=subtype,
        section_ids=[],
    )
    db.add(writing)
    await db.flush()
    return writing


async def _pick_publisher(
    db: AsyncSession,
    *,
    fallback: User,
    prefer_existing: bool,
) -> User:
    """Pick a random user to publish under. Falls back to the just-created
    author if no other users exist (or `prefer_existing` is False)."""
    if not prefer_existing:
        return fallback
    result = await db.execute(select(User.id).where(User.id != fallback.id))
    ids = [row[0] for row in result.all()]
    if not ids:
        return fallback
    chosen_id = random.choice(ids)
    return (await db.execute(select(User).where(User.id == chosen_id))).scalar_one()
