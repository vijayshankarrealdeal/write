"""Section read-through helpers — replaces the deprecated `feed_items.sections`
JSONB snapshot.

Sections live canonically in the `sections` table, owned by the source
`Writing`. Readers reach them through the public `feed_items` projection
of that writing. This module is the single funnel for that read path:

* `list_section_stubs(...)` returns ordered `{section_id, title,
  updated_at, has_image}` for the chapter list — small, cacheable, used
  by `GET /api/feed/{id}`.
* `get_section_content(...)` returns one section's full Quill body for
  the lazy-load endpoint `GET /api/feed/{id}/sections/{section_id}`.

Ordering follows `Writing.section_ids[]` — that array is the author's
canonical chapter order, mutable as they add/remove/reorder. Sections
that exist in the table but aren't in `section_ids` (orphaned by an
incomplete delete) are dropped from the list, matching what the editor
would show the author.
"""
from __future__ import annotations

import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.section import Section
from app.models.writing import Writing


def _has_image(content) -> bool:
    """True if any Quill `insert: {image: ...}` op is present in `content`.

    Powers the `_has_image` chapter-list dot in the reader UI without
    forcing the client to parse Quill on every render. Cheap heuristic
    — the section either embeds an image inline or it doesn't.
    """
    if not isinstance(content, list):
        return False
    for op in content:
        if isinstance(op, dict) and isinstance(op.get("insert"), dict) and "image" in op["insert"]:
            return True
    return False


async def list_section_stubs(
    db: AsyncSession, writing_id: uuid.UUID
) -> list[dict]:
    """Ordered list of section stubs for a writing.

    Each stub: `{section_id, title, updated_at, has_image, _lazy: True}`.
    `_lazy: True` matches the legacy contract — the client knows the
    body is fetched separately. No `content` is returned; readers pull
    each chapter via `/api/feed/{id}/sections/{section_id}` on demand.

    Returns `[]` if the writing has no sections, or if its `section_ids`
    array is empty (e.g. a brand-new draft with no chapters yet).
    """
    writing = (
        await db.execute(
            select(Writing.section_ids).where(Writing.id == writing_id)
        )
    ).scalar_one_or_none()
    if not writing:
        return []
    ordered_ids: list[str] = list(writing or [])
    if not ordered_ids:
        return []

    parsed_ids: list[uuid.UUID] = []
    for sid in ordered_ids:
        try:
            parsed_ids.append(uuid.UUID(str(sid)))
        except (ValueError, TypeError):
            continue
    if not parsed_ids:
        return []

    # Reader-only filter: include only chapters the author ticked at
    # publish time. The author's own editor view (via /api/writings/...)
    # is unaffected — they keep seeing every section they own.
    rows = (
        await db.execute(
            select(
                Section.id,
                Section.title,
                Section.content,
                Section.updated_at,
            ).where(
                Section.id.in_(parsed_ids),
                Section.is_published.is_(True),
            )
        )
    ).all()
    by_id = {r.id: r for r in rows}

    out: list[dict] = []
    for sid in ordered_ids:
        try:
            uid = uuid.UUID(str(sid))
        except (ValueError, TypeError):
            continue
        row = by_id.get(uid)
        if row is None:
            continue
        out.append(
            {
                "section_id": str(row.id),
                "title": row.title,
                "updated_at": row.updated_at.isoformat() if row.updated_at else None,
                "_has_image": _has_image(row.content),
                "_lazy": True,
            }
        )
    return out


async def get_section_content(
    db: AsyncSession,
    *,
    writing_id: uuid.UUID,
    section_id: uuid.UUID,
) -> dict | None:
    """Fetch one section's body, scoped to the given writing.

    Returns `{section_id, title, content, canvasData, updated_at,
    _has_image}` or None if the section either doesn't exist OR doesn't
    belong to the requested writing. The writing scope is what makes
    this safe — a malicious client can't enumerate sections by guessing
    UUIDs and walking writings they don't own.
    """
    row = (
        await db.execute(
            select(
                Section.id,
                Section.title,
                Section.content,
                Section.canvas_data,
                Section.updated_at,
            ).where(
                Section.id == section_id,
                Section.writing_id == writing_id,
                Section.is_published.is_(True),
            )
        )
    ).one_or_none()
    if row is None:
        return None
    return {
        "section_id": str(row.id),
        "title": row.title,
        "content": row.content,
        "canvasData": row.canvas_data,
        "updated_at": row.updated_at.isoformat() if row.updated_at else None,
        "_has_image": _has_image(row.content),
    }


async def section_id_at_index(
    db: AsyncSession, writing_id: uuid.UUID, index: int
) -> uuid.UUID | None:
    """Translate a 0-based index into a section UUID, walking only the
    PUBLISHED slice of `Writing.section_ids[]`.

    Used by the legacy `/api/feed/{id}/sections/{index}` endpoint while
    the Flutter client migrates to UUID-keyed pagination. The index is
    a position into the reader's view (published chapters in author
    order), not the author's full draft list — so unticked drafts are
    skipped over before counting.
    """
    writing = (
        await db.execute(
            select(Writing.section_ids).where(Writing.id == writing_id)
        )
    ).scalar_one_or_none()
    if not writing:
        return None
    ordered_ids: list[str] = list(writing or [])
    if not ordered_ids:
        return None
    parsed_ids: list[uuid.UUID] = []
    for sid in ordered_ids:
        try:
            parsed_ids.append(uuid.UUID(str(sid)))
        except (ValueError, TypeError):
            continue
    if not parsed_ids:
        return None
    published_ids: set[uuid.UUID] = {
        r
        for (r,) in (
            await db.execute(
                select(Section.id).where(
                    Section.id.in_(parsed_ids),
                    Section.is_published.is_(True),
                )
            )
        ).all()
    }
    published_in_order = [pid for pid in parsed_ids if pid in published_ids]
    if index < 0 or index >= len(published_in_order):
        return None
    return published_in_order[index]


async def flatten_writing_text(
    db: AsyncSession, writing_id: uuid.UUID, *, char_limit: int
) -> str:
    """Concatenate a writing's section bodies into plain text up to
    `char_limit` characters. Used by the embedding pipeline to produce
    semantic embeddings now that `feed_items.sections` is gone.

    Walks `Section.content` (Quill Delta `[{insert: "..."}]` shape) and
    extracts the string-typed `insert` ops — same heuristic that used
    to live in `_flatten_section_text`. Stops as soon as we cross
    `char_limit` so we don't shovel a 1000-section book into the
    tokenizer.
    """
    # Match the reader-side filter — embeddings should reflect what the
    # public actually reads, not the author's draft pile.
    rows = (
        await db.execute(
            select(Section.content)
            .where(Section.writing_id == writing_id)
            .where(Section.is_published.is_(True))
        )
    ).all()
    chunks: list[str] = []
    total = 0
    for (content,) in rows:
        if not isinstance(content, list):
            continue
        for op in content:
            if isinstance(op, dict) and isinstance(op.get("insert"), str):
                chunks.append(op["insert"])
                total += len(op["insert"])
                if total >= char_limit:
                    return "\n".join(chunks)[:char_limit]
    return "\n".join(chunks)[:char_limit]


async def set_published_section_ids(
    db: AsyncSession,
    *,
    writing_id: uuid.UUID,
    published_ids: list[uuid.UUID],
) -> None:
    """Atomically set `is_published` for every section under [writing_id].

    Sections whose id is in `published_ids` flip to True; every other
    section under the writing flips to False. One UPDATE; matches the
    Instagram-style "select what to publish" UX where the author hits
    a single "Publish" action with a chosen set.

    Caller must commit. Caller must verify writing ownership.
    """
    from sqlalchemy import update

    await db.execute(
        update(Section)
        .where(Section.writing_id == writing_id)
        .values(is_published=Section.id.in_(published_ids))
    )


__all__ = [
    "list_section_stubs",
    "get_section_content",
    "section_id_at_index",
    "flatten_writing_text",
    "set_published_section_ids",
]
