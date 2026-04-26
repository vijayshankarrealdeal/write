"""Phase 2 — drill-down + filters.

Schema-only tests: the cursor and sort helpers are pure, deterministic
functions over SQLAlchemy expression trees and stand-in `FeedItem`
rows. Full pagination is verified in the integration suite (which
requires a live Postgres) — see `_apply_cursor` for the contract these
tests pin down.
"""
from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

from app.routers.feed import _apply_cursor, _apply_sort
from sqlalchemy import select

from app.models.feed_item import FeedItem


def _row(*, likes: int, created: datetime) -> SimpleNamespace:
    return SimpleNamespace(
        id=uuid.uuid4(),
        likes_count=likes,
        created_at=created,
    )


def test_apply_sort_recent_orders_newest_first():
    base = select(FeedItem).where(FeedItem.is_draft.is_(False))
    out = _apply_sort(base, "recent")
    sql = str(out.compile(compile_kwargs={"literal_binds": True}))
    assert "ORDER BY feed_items.created_at DESC" in sql


def test_apply_sort_trending_orders_by_likes_then_recency():
    base = select(FeedItem)
    out = _apply_sort(base, "trending")
    sql = str(out.compile(compile_kwargs={"literal_binds": True}))
    assert "feed_items.likes_count DESC" in sql
    assert "feed_items.created_at DESC" in sql


def test_apply_sort_top_is_alias_for_trending():
    base = select(FeedItem)
    sql_top = str(_apply_sort(base, "top").compile(compile_kwargs={"literal_binds": True}))
    sql_trending = str(
        _apply_sort(base, "trending").compile(compile_kwargs={"literal_binds": True})
    )
    assert sql_top == sql_trending


def test_apply_cursor_recent_uses_strict_inequality():
    """Cursor-based pagination on the 'recent' sort must filter STRICTLY
    older than the cursor row, otherwise consecutive pages can repeat
    the boundary item."""
    base = select(FeedItem)
    cursor = _row(likes=10, created=datetime.now(UTC))
    out = _apply_cursor(base, "recent", cursor)
    sql = str(out.compile(compile_kwargs={"literal_binds": True}))
    assert "feed_items.created_at <" in sql


def test_apply_cursor_trending_paginates_by_likes_then_created_at():
    """Trending pagination must compare on (likes, created_at) — when
    likes are equal we still need to advance, otherwise the page
    boundary stalls on a tie."""
    base = select(FeedItem)
    older = datetime.now(UTC) - timedelta(days=1)
    cursor = _row(likes=5, created=older)
    out = _apply_cursor(base, "trending", cursor)
    sql = str(out.compile(compile_kwargs={"literal_binds": True}))
    assert "feed_items.likes_count <" in sql
    assert "feed_items.likes_count =" in sql
    assert "feed_items.created_at <" in sql
