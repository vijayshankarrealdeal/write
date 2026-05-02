"""Feed-item embedding pipeline.

When a writing is published (`is_draft → False`), we generate a vector
embedding from `title + description + first ~2000 chars of section text`
and persist it on the `feed_items.embedding` column. The embedding
powers semantic recommendations (Phase 1) — nearest-neighbour searches
in pgvector.

Design notes
------------
- The publish path **does not block** on embedding generation. We
  enqueue a fire-and-forget asyncio task; the user gets a 201 the
  moment the row is committed.
- Embedding failures are tolerated. A null embedding column simply
  means the item won't be semantically matched until the next backfill
  pass. The keyword/popularity scoring still works.
- We never re-embed an item that already has a non-null vector unless
  the caller explicitly forces it (used by the backfill script when
  re-running with a new model).
- Body text is sourced live from the `sections` table via
  `feed_sections.flatten_writing_text` — when an author edits a
  chapter, the next embedding pass picks up the changes without
  needing a republish.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Iterable
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.client import ai_configured
from app.ai.writer_agent import get_embedding
from app.database import async_session
from app.feed_sections import flatten_writing_text
from app.models.feed_item import FeedItem

log = logging.getLogger("app.ai.embeddings")

# How many characters of body text we feed the embedding model. Beyond
# ~2k chars the marginal signal-to-cost ratio drops sharply.
_BODY_CHAR_LIMIT = 2000


async def build_embedding_text(item: FeedItem, db: AsyncSession) -> str:
    """Compose the input string we feed the embedding model.

    `title + description + first ~2000 chars of body`. Body comes from
    the `sections` table joined via `item.writing_id`. When the writing
    has no FK or no sections, we fall back to title+description only —
    not great for KNN but better than failing the embedding outright.
    """
    parts: list[str] = []
    if item.title:
        parts.append(item.title.strip())
    if item.description:
        parts.append(item.description.strip())
    if item.writing_id is not None:
        body = await flatten_writing_text(
            db, item.writing_id, char_limit=_BODY_CHAR_LIMIT
        )
        if body:
            parts.append(body)
    return "\n\n".join(p for p in parts if p)


async def embed_feed_item(
    feed_item_id: UUID | str,
    *,
    db: AsyncSession | None = None,
    force: bool = False,
) -> bool:
    """Generate + persist an embedding for a single feed item.

    Returns True on success, False on any expected miss (no AI configured,
    not found, draft, already has an embedding without `force`).
    """
    if not ai_configured():
        return False

    own_session = db is None
    session = db or async_session()
    try:
        try:
            fid = UUID(str(feed_item_id))
        except (ValueError, TypeError):
            return False

        result = await session.execute(select(FeedItem).where(FeedItem.id == fid))
        item = result.scalar_one_or_none()
        if item is None or item.is_draft:
            return False
        if item.embedding is not None and not force:
            return False

        text = await build_embedding_text(item, session)
        if not text:
            return False

        try:
            emb = await get_embedding(text)
        except Exception:
            log.exception("embedding generation failed for %s", fid)
            return False

        item.embedding = emb.embedding
        await session.commit()
        return True
    finally:
        if own_session:
            await session.close()


def schedule_embedding(feed_item_id: UUID | str) -> None:
    """Fire-and-forget embedding update.

    Caller must have already committed the FeedItem row; we open our
    own session inside the task so we don't fight for the caller's
    transaction.
    """
    if not ai_configured():
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    loop.create_task(_run_embedding_quietly(feed_item_id))


async def _run_embedding_quietly(feed_item_id: UUID | str) -> None:
    try:
        await embed_feed_item(feed_item_id)
    except Exception:
        log.exception("background embedding task crashed for %s", feed_item_id)


async def embed_many(
    ids: Iterable[UUID | str],
    *,
    force: bool = False,
) -> tuple[int, int]:
    """Sequentially embed a batch. Returns (successes, attempts).

    Used by the backfill script. Sequential rather than concurrent on
    purpose: Azure OpenAI rate limits are easier to honour at one
    request at a time.
    """
    ok = 0
    total = 0
    for fid in ids:
        total += 1
        if await embed_feed_item(fid, force=force):
            ok += 1
    return ok, total
