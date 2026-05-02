"""Single-call home feed composer — the "shelves" architecture.

One `GET /api/feed/home` returns every rail the home page renders, in
display order, deduplicated globally. An item that qualifies for two
rails (e.g. trending AND new release) only surfaces in the higher-
priority rail. This keeps the user from scrolling past the same book
three times.

Each rail has its own candidate generator. Generators run in parallel
(`asyncio.gather`) so total latency is roughly the slowest rail, not
the sum. After fan-in, a single materialization query hydrates every
unique id into a `FeedItem` row — keeps the wire path tight and
guarantees one consistent privacy gate (`public_feed_clause`) even if
a generator forgot it.

The rail order below is BOTH the display order AND the dedup priority:
when a book qualifies for `trending_now` and `new_release`, it appears
only in `new_release` (which sits earlier in the list). Reorder this
list to reorder the home page.

Cold-start: every rail except `continue_reading` works from day one
without per-user signals — featured/trending/top fall back to global
engagement, recommendation has its own onboarding-genre fallback in
`recommend_for_user`, hidden_gems and editor_picks are algorithmic.
`continue_reading` is omitted when the user has no in-progress reads.

Future work (deliberately not built here):
  * Admin-set `is_featured` / `is_editor_pick` flags overriding the
    algorithmic v1.
  * Per-user/per-rail seen tracking so rails freshen across visits.
  * Response-level cache (~60s TTL) keyed on user id.
"""
from __future__ import annotations

import asyncio
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Awaitable, Callable

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.feed_visibility import public_feed_clause
from app.models.feed_item import FeedItem
from app.models.reading_progress import ReadingProgress
from app.models.user import User


# ---------------------------------------------------------------------------
# Rail definitions
# ---------------------------------------------------------------------------

# Generator signature: (user, db, fetch_limit) -> ordered list of FeedItem ids.
# `fetch_limit` is rail.limit * OVERFETCH so the composer has room to dedup
# without short-changing later rails.
_Gen = Callable[[User, AsyncSession, int], Awaitable[list[uuid.UUID]]]


@dataclass(frozen=True)
class RailDef:
    rail_id: str
    title: str
    generator: _Gen
    limit: int = 10


# Multiplier on each rail's fetch — gives the composer headroom when
# earlier rails consume an item this rail also wanted.
_OVERFETCH = 2


# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------
# Every generator MUST apply `public_feed_clause(user.id)` so private
# writings only surface to approved followers. Self-authored items are
# excluded so the user's own work doesn't show up in their own home.


async def _featured(user: User, db: AsyncSession, limit: int) -> list[uuid.UUID]:
    """Top engagement of the last 30 days. Will be replaced by an
    admin-set `is_featured` flag once curation tooling exists."""
    cutoff = datetime.now(UTC) - timedelta(days=30)
    stmt = (
        select(FeedItem.id)
        .where(public_feed_clause(user.id))
        .where(FeedItem.author_id != user.id)
        .where(FeedItem.created_at >= cutoff)
        .order_by(
            (FeedItem.likes_count + 3 * FeedItem.comments_count).desc(),
            FeedItem.created_at.desc(),
        )
        .limit(limit)
    )
    return list((await db.execute(stmt)).scalars().all())


async def _continue_reading(user: User, db: AsyncSession, limit: int) -> list[uuid.UUID]:
    """User's unfinished reads, freshest first. Joined through the
    visibility gate so books that went private after the user started
    reading them don't surface (the title vanishes from the rail; the
    reader's separate history view still keeps the entry)."""
    stmt = (
        select(FeedItem.id)
        .join(ReadingProgress, ReadingProgress.feed_item_id == FeedItem.id)
        .where(ReadingProgress.user_id == user.id)
        .where(ReadingProgress.completed.is_(False))
        .where(public_feed_clause(user.id))
        .order_by(ReadingProgress.last_read_at.desc().nullslast())
        .limit(limit)
    )
    return list((await db.execute(stmt)).scalars().all())


async def _new_release(user: User, db: AsyncSession, limit: int) -> list[uuid.UUID]:
    """Books published in the last 7 days, newest first."""
    cutoff = datetime.now(UTC) - timedelta(days=7)
    stmt = (
        select(FeedItem.id)
        .where(public_feed_clause(user.id))
        .where(FeedItem.author_id != user.id)
        .where(FeedItem.created_at >= cutoff)
        .order_by(FeedItem.created_at.desc())
        .limit(limit)
    )
    return list((await db.execute(stmt)).scalars().all())


async def _recommendation(user: User, db: AsyncSession, limit: int) -> list[uuid.UUID]:
    """Personalized — delegates to the existing recommendation engine.
    Best-effort: a recommender failure (e.g. embedding service down)
    returns an empty list rather than failing the whole home page."""
    try:
        from app.ai.recommendation import recommend_for_user
        rec = await recommend_for_user(user, db, limit=limit, use_llm_rerank=False)
        return [uuid.UUID(item.feed_item_id) for item in rec.items]
    except Exception:
        return []


async def _trending_now(user: User, db: AsyncSession, limit: int) -> list[uuid.UUID]:
    """Hot-right-now: high engagement weighted toward recency.
    `likes + 2*comments` over a 14-day window approximates 'velocity'
    cheaply without a window function or analytics rollup."""
    cutoff = datetime.now(UTC) - timedelta(days=14)
    stmt = (
        select(FeedItem.id)
        .where(public_feed_clause(user.id))
        .where(FeedItem.author_id != user.id)
        .where(FeedItem.created_at >= cutoff)
        .order_by(
            (FeedItem.likes_count + 2 * FeedItem.comments_count).desc(),
            FeedItem.created_at.desc(),
        )
        .limit(limit)
    )
    return list((await db.execute(stmt)).scalars().all())


async def _top_10_week(user: User, db: AsyncSession, limit: int) -> list[uuid.UUID]:
    """Most-liked books from the last 7 days. Different from `trending_now`
    by window (7d vs 14d) and by ordering (pure likes vs likes+comments
    blend) — surfaces this week's clear winners rather than items
    accelerating fast."""
    cutoff = datetime.now(UTC) - timedelta(days=7)
    stmt = (
        select(FeedItem.id)
        .where(public_feed_clause(user.id))
        .where(FeedItem.author_id != user.id)
        .where(FeedItem.created_at >= cutoff)
        .order_by(FeedItem.likes_count.desc(), FeedItem.created_at.desc())
        .limit(limit)
    )
    return list((await db.execute(stmt)).scalars().all())


async def _hidden_gems(user: User, db: AsyncSession, limit: int) -> list[uuid.UUID]:
    """Quality-but-underexposed: items that earned discussion (>=1 comment)
    but haven't broken out yet (1-30 likes). Recent-only so the rail
    refreshes — no point rediscovering year-old gems forever."""
    cutoff = datetime.now(UTC) - timedelta(days=30)
    stmt = (
        select(FeedItem.id)
        .where(public_feed_clause(user.id))
        .where(FeedItem.author_id != user.id)
        .where(FeedItem.created_at >= cutoff)
        .where(FeedItem.likes_count.between(1, 30))
        .where(FeedItem.comments_count >= 1)
        .order_by(FeedItem.created_at.desc())
        .limit(limit)
    )
    return list((await db.execute(stmt)).scalars().all())


async def _editor_picks(user: User, db: AsyncSession, limit: int) -> list[uuid.UUID]:
    """Algorithmic stand-in for editorial curation: high-engagement books
    (5+ comments AND 20+ likes) ordered by likes. Replace with an admin-
    set `is_editor_pick` flag once curation tooling exists."""
    stmt = (
        select(FeedItem.id)
        .where(public_feed_clause(user.id))
        .where(FeedItem.author_id != user.id)
        .where(FeedItem.comments_count >= 5)
        .where(FeedItem.likes_count >= 20)
        .order_by(FeedItem.likes_count.desc())
        .limit(limit)
    )
    return list((await db.execute(stmt)).scalars().all())


# Rail order = display order = dedup priority. Items qualifying for two
# rails surface only in the rail listed first.
RAILS: list[RailDef] = [
    RailDef("featured", "Featured", _featured, limit=5),
    RailDef("continue_reading", "Continue Reading", _continue_reading, limit=10),
    RailDef("new_release", "New Releases", _new_release, limit=10),
    RailDef("recommendation", "For You", _recommendation, limit=15),
    RailDef("trending_now", "Trending Now", _trending_now, limit=10),
    RailDef("top_10_week", "Top 10 This Week", _top_10_week, limit=10),
    RailDef("hidden_gems", "Discover Hidden Gems", _hidden_gems, limit=10),
    RailDef("editor_picks", "Editor's Picks", _editor_picks, limit=8),
]


# ---------------------------------------------------------------------------
# Composer
# ---------------------------------------------------------------------------


async def compose_home(user: User, db: AsyncSession) -> list[dict]:
    """Run every rail in parallel, dedup globally, materialize once.

    Returns a list of `{rail_id, title, items}` dicts in display order.
    Empty rails are dropped so the client doesn't render hollow shelves.
    """
    fetch_results = await asyncio.gather(
        *[rail.generator(user, db, rail.limit * _OVERFETCH) for rail in RAILS],
        return_exceptions=True,
    )

    seen: set[uuid.UUID] = set()
    rail_orders: list[tuple[RailDef, list[uuid.UUID]]] = []
    for rail, ids in zip(RAILS, fetch_results):
        if isinstance(ids, BaseException):
            # One rail's failure shouldn't sink the page — log and skip.
            # (We rely on FastAPI's logging middleware to capture the trace.)
            continue
        deduped = [iid for iid in ids if iid not in seen][: rail.limit]
        if deduped:
            seen.update(deduped)
            rail_orders.append((rail, deduped))

    if not seen:
        return []

    # Single materialization. Re-applies the visibility gate as defense-
    # in-depth — if a generator forgot to add it, the gate here still
    # filters private items the viewer can't read.
    rows = (
        await db.execute(
            select(FeedItem)
            .where(FeedItem.id.in_(seen))
            .where(public_feed_clause(user.id))
        )
    ).scalars().all()
    items_by_id: dict[uuid.UUID, FeedItem] = {it.id: it for it in rows}

    out: list[dict] = []
    for rail, ids in rail_orders:
        ordered = [items_by_id[iid] for iid in ids if iid in items_by_id]
        if not ordered:
            continue
        # Strip the heavy `sections` JSONB from home cards — readers
        # fetch chapters lazily via `/api/feed/{id}/sections/{i}`. For a
        # 1400-section book this saves ~30 MB per home request.
        slim_items = []
        for item in ordered:
            slim = {
                "id": item.id,
                "title": item.title,
                "author": item.author,
                "author_id": item.author_id,
                "writing_id": item.writing_id,
                "description": item.description,
                "image_url": item.image_url,
                "image_meta": item.image_meta,
                "genres": item.genres or [],
                "writing_types": item.writing_types or [],
                "tags": item.tags or [],
                "likes_count": item.likes_count or 0,
                "comments_count": item.comments_count or 0,
                "is_draft": item.is_draft,
                "sections": None,
                "created_at": item.created_at,
                "updated_at": item.updated_at,
            }
            slim_items.append(slim)
        out.append({"rail_id": rail.rail_id, "title": rail.title, "items": slim_items})

    return out
