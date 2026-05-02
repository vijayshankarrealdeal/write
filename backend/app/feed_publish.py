"""Feed-card publishing — the single backend-side projection from a
Writing to a public FeedItem.

Two callers reach this module:

* The public `POST /api/feed/` route, after it validates that the
  writing belongs to the requesting user.
* The ingest pipeline at `test_model/book_ingest/db_publish.py`, which
  uploads books like Frankenstein / Mahābhārata under a "publisher"
  identity that may differ from the writing's author user.

Both paths must produce a card whose `writing_id` FK points at the
source writing — that's what makes the `writings -> feed_items`
ON DELETE CASCADE fire when the writing is deleted. Centralising the
logic here is the only way to guarantee that property: any future
caller that needs to publish a writing goes through this module and
inherits the FK by construction.
"""
from __future__ import annotations

import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.embeddings import schedule_embedding
from app.models.feed_item import FeedItem
from app.models.user import User


async def upsert_feed_item_for_writing(
    db: AsyncSession,
    *,
    writing_id: uuid.UUID,
    publisher: User,
    title: str | None,
    description: str | None = None,
    image_url: str | None = None,
    image_meta: dict | None = None,
    genres: list[str] | None = None,
    writing_types: list[str] | None = None,
    tags: list[str] | None = None,
    is_draft: bool = False,
    visibility: str = "public",
) -> FeedItem:
    """Create or update the feed card for [writing_id].

    Idempotent on the `writing_id` unique key: a second call updates the
    existing card in place rather than producing a sibling — which is
    what made the pre-FK code accumulate duplicate cards on every
    republish. Returns the live row, with embedding scheduled when the
    card is no longer a draft.

    The caller owns authorization. Public API callers must verify
    `writing.user_id == publisher.id` before invoking; ingest paths
    intentionally publish under a different identity than the writing's
    owner and pass that user as [publisher].
    """
    existing = (
        await db.execute(select(FeedItem).where(FeedItem.writing_id == writing_id))
    ).scalar_one_or_none()

    fields: dict = {
        "title": title,
        "description": description,
        "image_url": image_url,
        "image_meta": image_meta,
        "genres": genres or [],
        "writing_types": writing_types or [],
        "tags": tags or [],
        "is_draft": is_draft,
        "visibility": visibility,
    }
    # Note: section bodies live in the `sections` table, owned by the
    # source `Writing`. The publish path used to denormalize them into
    # a `feed_items.sections` JSONB column for read-path performance,
    # but that snapshot meant author edits (typo fixes, new chapters,
    # removed chapters) wouldn't reach readers without a republish —
    # the wrong default for a serial-content product. Reads now go
    # straight to the `sections` table via `app.feed_sections`.

    if existing is not None:
        # Preserve the original publisher identity on update — re-publishing
        # under a different account would silently move the card and break
        # author-page listings for anyone already linked to the original.
        for key, value in fields.items():
            setattr(existing, key, value)
        item = existing
    else:
        item = FeedItem(
            writing_id=writing_id,
            author=publisher.name,
            author_id=publisher.id,
            **fields,
        )
        db.add(item)

    await db.commit()
    await db.refresh(item)
    if not item.is_draft:
        schedule_embedding(item.id)
    return item
