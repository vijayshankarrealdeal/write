"""Track 1 — Follow-Graph Signal.

Today the `follows` table is consulted by the visibility predicate only:
private items surface to approved followers. The ranking pipeline ignores
it. That's leaving the loudest declared-interest signal in the database
on the floor — a user who hit Follow has literally told us "show me more
of this person." This module turns the follow graph into:

1. A ranking boost (`follow_boost`): items by a followed author get a
   flat additive bump in the scorer. Pure function so the integrator can
   call it inside the hot scoring loop without paying a DB hit per item.
2. A candidate-pool stratum (`followed_author_candidates`): newest public
   non-draft items by followed authors. Pulled separately from the
   existing recent/popular/interest strata so a brand-new piece by
   someone the user follows can't fall off the bottom of the recency
   limit before it's seen.

Track 6 wires both into [recommendation.py](../recommendation.py); this
module does not import or modify the recommender itself.

The `FOLLOW_BOOST = 4.0` constant is exposed so the integrator (and
tests) can refer to it symbolically. The value was picked to sit
between the semantic-match weight (~3.0 at a perfect cosine match) and
the strongest engagement signals — a follow is a stronger declaration
than a single like, weaker than completing a book.
"""
from __future__ import annotations

from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.feed_visibility import public_feed_clause
from app.models.feed_item import FeedItem
from app.models.follow import Follow


# Additive bump applied to an item's score when its author is in the
# viewer's followed-author set. See module docstring for tuning notes.
FOLLOW_BOOST: float = 4.0


async def get_followed_author_ids(
    db: AsyncSession, user_id: UUID
) -> set[UUID]:
    """Return the set of author user ids the given user follows with
    `status = 'approved'`.

    'pending' follows are excluded on purpose: a request the followee
    hasn't approved doesn't grant either the visibility access or the
    ranking boost. A 'pending' row is just an inbox item.

    Single SELECT; returns an empty set when the user follows nobody.
    The caller is expected to invoke this once per request and reuse
    the result for both the candidate query and the per-item boost,
    so this function does no caching of its own.
    """
    stmt = select(Follow.followee_id).where(
        Follow.follower_id == user_id,
        Follow.status == "approved",
    )
    result = await db.execute(stmt)
    return set(result.scalars().all())


def follow_boost(item_author_id: UUID, followed_ids: set[UUID]) -> float:
    """Return `FOLLOW_BOOST` if the item's author is in `followed_ids`,
    else `0.0`.

    Pure function — no DB, safe to call inside a tight scoring loop.
    The caller is expected to pre-fetch `followed_ids` once via
    `get_followed_author_ids` and pass it in.
    """
    if item_author_id in followed_ids:
        return FOLLOW_BOOST
    return 0.0


async def followed_author_candidates(
    db: AsyncSession,
    user_id: UUID,
    followed_ids: set[UUID],
    limit: int = 100,
    days: int = 30,
) -> list[UUID]:
    """Return recent public non-draft feed_item ids whose author_id is
    in `followed_ids`.

    Newest first, capped to `limit`. The requesting user's own items
    are excluded (they shouldn't see their own work in their feed even
    if they somehow follow themselves — the model forbids it, but the
    extra clause is cheap insurance).

    `public_feed_clause(user_id)` is applied so the result respects
    Instagram-style per-item privacy: a private item by a followed
    author surfaces only when the viewer's follow is `approved`. Drafts
    are filtered by the same helper.

    `days` bounds the window so the query stays anchored to recency
    even when a user follows a prolific author with years of back
    catalogue. Defaults to 30, matching the "what's new" framing of
    the followed-author stratum.

    Returns an empty list when `followed_ids` is empty — the caller
    can skip wiring this stratum entirely without a DB round trip in
    that case, but the early return guards against an `IN ()` becoming
    a costly full-table scan if it ever slips through.
    """
    if not followed_ids:
        return []

    # `interval` is parameterised through SQLAlchemy's `text` form via the
    # `now() - make_interval(...)` pattern; using a Python `timedelta`
    # keeps the value in the driver's typed parameter space and avoids
    # any SQL-construction surprises across dialects.
    from datetime import datetime, timedelta, timezone

    cutoff = datetime.now(timezone.utc) - timedelta(days=days)

    stmt = (
        select(FeedItem.id)
        .where(
            public_feed_clause(user_id),
            FeedItem.author_id.in_(followed_ids),
            FeedItem.author_id != user_id,
            FeedItem.created_at >= cutoff,
        )
        .order_by(FeedItem.created_at.desc())
        .limit(limit)
    )
    result = await db.execute(stmt)
    return list(result.scalars().all())


__all__ = [
    "FOLLOW_BOOST",
    "get_followed_author_ids",
    "follow_boost",
    "followed_author_candidates",
]
