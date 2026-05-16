"""Already-shown dedup for the home-feed recommender.

Without this filter a user who refreshes the home feed sees the same
top-scoring items over and over — the #1 UX complaint of every new
recsys. We already log every impression to ``recommendation_events``;
this module is the read side of that ledger.

Two helpers, deliberately tiny:

* :func:`get_recently_seen_ids` — async DB lookup, returns the set of
  feed-item ids the user had an ``impression`` event for in the last
  ``days`` days. ``click`` events are intentionally excluded — engaged
  content is fair game to re-surface later (a user who liked Chapter 1
  may want Chapter 1 again next week).
* :func:`filter_seen` — pure function, drops seen ids from a ranked
  candidate list. The ``keep_top_n`` knob preserves the top N ids even
  if seen so beloved evergreens can return (e.g. the staff-pick at slot
  0 shouldn't vanish just because the user scrolled past it yesterday).

The query is backed by the partial index
``ix_rec_events_user_type_time`` added in migration
``20260516_01_recommendation_event_index``; without that index the
``WHERE user_id = ? AND event_type = 'impression' AND created_at > ?``
scan would degrade as ``recommendation_events`` grows. Track 6 of
``recommendation_new.md`` wires both helpers into
``app.ai.recommendation``.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.analytics import RecommendationEvent


# The "recently seen" window. 10 days is long enough that a daily user
# doesn't see the same card twice in a normal browsing rhythm, and short
# enough that genuinely loved items can come back after a couple of
# weeks. Lower than the per-author diversity decay window so the
# diversity pass still has room to maneuver.
DEFAULT_SEEN_WINDOW_DAYS: int = 10


async def get_recently_seen_ids(
    db: AsyncSession,
    user_id: UUID,
    days: int = DEFAULT_SEEN_WINDOW_DAYS,
) -> set[UUID]:
    """Return feed_item_ids the user had an 'impression' event for in the
    last ``days`` days.

    Excludes ``click`` events on purpose: a click is engagement, and an
    engaged item is safe to re-show eventually (the user may want to
    revisit it). The filter exists to suppress *unwatched* repeats, not
    to permanently retire anything the user ever saw.

    A non-positive ``days`` returns an empty set without hitting the DB
    — convenient for callers that toggle the filter off via config.
    """
    if days <= 0:
        return set()

    cutoff = datetime.now(UTC) - timedelta(days=days)

    stmt = (
        select(RecommendationEvent.feed_item_id)
        .where(
            RecommendationEvent.user_id == user_id,
            RecommendationEvent.event_type == "impression",
            RecommendationEvent.created_at > cutoff,
        )
        .distinct()
    )
    rows = (await db.execute(stmt)).scalars().all()
    return {row for row in rows if row is not None}


def filter_seen(
    candidates: list[UUID],
    seen: set[UUID],
    keep_top_n: int = 0,
) -> list[UUID]:
    """Drop ``seen`` ids from ``candidates``.

    If ``keep_top_n > 0`` the first ``keep_top_n`` candidates are kept
    as-is even when seen, so evergreen heroes at the top of the ranked
    list survive the filter. Order is preserved; the function is pure —
    no DB, no mutation of inputs.

    Empty ``seen`` (or empty ``candidates``) short-circuits to a fresh
    list to avoid surprising the caller with the same object back.
    """
    if not candidates:
        return []
    if not seen:
        return list(candidates)

    keep_n = max(0, keep_top_n)
    out: list[UUID] = []
    for idx, cid in enumerate(candidates):
        if idx < keep_n:
            out.append(cid)
            continue
        if cid in seen:
            continue
        out.append(cid)
    return out
