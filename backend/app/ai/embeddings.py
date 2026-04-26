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
- We coalesce text from the JSONB `sections` column (Quill Delta-ish
  shape) — cheap heuristic, not perfect, but good enough for KNN.
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
from app.models.feed_item import FeedItem

log = logging.getLogger("app.ai.embeddings")

# How many characters of body text we feed the embedding model. Beyond
# ~2k chars the marginal signal-to-cost ratio drops sharply.
_BODY_CHAR_LIMIT = 2000


def _flatten_section_text(sections: list[dict] | None) -> str:
    """Best-effort plain-text extraction from a JSONB sections array.

    The schema isn't fully normalised — sections can carry plain `text`,
    or a Quill `ops` delta, or a list of `paragraphs`. We try each in
    turn and concatenate whatever we find. Worst case we get the empty
    string and fall back to title + description only.
    """
    if not sections:
        return ""
    chunks: list[str] = []
    for sec in sections:
        if not isinstance(sec, dict):
            continue
        if isinstance(sec.get("text"), str):
            chunks.append(sec["text"])
            continue
        ops = sec.get("ops")
        if isinstance(ops, list):
            for op in ops:
                if isinstance(op, dict) and isinstance(op.get("insert"), str):
                    chunks.append(op["insert"])
            continue
        paragraphs = sec.get("paragraphs")
        if isinstance(paragraphs, list):
            for p in paragraphs:
                if isinstance(p, str):
                    chunks.append(p)
                elif isinstance(p, dict) and isinstance(p.get("text"), str):
                    chunks.append(p["text"])
    return "\n".join(chunks)


def build_embedding_text(item: FeedItem) -> str:
    """Compose the input string we feed the embedding model."""
    parts: list[str] = []
    if item.title:
        parts.append(item.title.strip())
    if item.description:
        parts.append(item.description.strip())
    body = _flatten_section_text(item.sections)
    if body:
        parts.append(body[:_BODY_CHAR_LIMIT])
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

        text = build_embedding_text(item)
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
