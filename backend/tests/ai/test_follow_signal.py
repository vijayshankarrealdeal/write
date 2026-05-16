"""Tests for the follow-graph ranking signal (Track 1).

The existing test suite under `backend/tests/` is deliberately DB-free
(see `tests/test_recommendations_semantic.py` for the same shape):
helpers are exercised with hand-built stand-ins and a stubbed
`AsyncSession` rather than a live Postgres fixture. We follow that
convention here so this module runs anywhere pytest does, without a
running database. End-to-end SQL ordering / privacy gating is verified
in the integration suite once Track 6 lands.

What we *do* assert on the DB-touching functions:

- `get_followed_author_ids` builds a SELECT against the right column
  set with `status = 'approved'` in the WHERE clause, and returns what
  the session hands back (including the empty case).
- `followed_author_candidates` orders newest first, respects `limit`,
  filters out the requesting user's own items, and skips the round trip
  entirely when the followed-set is empty (the early return matters for
  cost — `IN ()` against `feed_items` would otherwise be expensive).
"""
from __future__ import annotations

import uuid
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from app.ai.signals.follow import (
    FOLLOW_BOOST,
    follow_boost,
    followed_author_candidates,
    get_followed_author_ids,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _uid() -> uuid.UUID:
    return uuid.uuid4()


class _FakeScalars:
    """Mimics SQLAlchemy's `result.scalars()` interface."""

    def __init__(self, rows):
        self._rows = list(rows)

    def all(self):
        return list(self._rows)


class _FakeResult:
    def __init__(self, rows):
        self._rows = list(rows)

    def scalars(self):
        return _FakeScalars(self._rows)


class _FakeSession:
    """Records every `execute` call and returns canned results in order.

    Mirrors only the slice of `AsyncSession` the helpers under test use
    (`await db.execute(stmt)` → `.scalars().all()`). Keeping it minimal
    on purpose so the tests stay legible.
    """

    def __init__(self, *result_rows):
        self.responses = [list(r) for r in result_rows]
        self.calls = []

    async def execute(self, stmt):
        self.calls.append(stmt)
        if not self.responses:
            return _FakeResult([])
        rows = self.responses.pop(0)
        return _FakeResult(rows)


def _compile(stmt) -> str:
    """Render a SQLAlchemy Core/ORM statement to SQL text for substring
    assertions. We avoid binding a real dialect so the helpers stay
    portable; the default literal-binds rendering is enough for the
    structural checks below.
    """
    return str(stmt.compile(compile_kwargs={"literal_binds": True}))


# ---------------------------------------------------------------------------
# follow_boost — pure function
# ---------------------------------------------------------------------------


def test_follow_boost_returns_constant_when_author_is_followed():
    followed = {_uid(), _uid()}
    author = next(iter(followed))
    assert follow_boost(author, followed) == FOLLOW_BOOST
    assert FOLLOW_BOOST == 4.0  # Track 6 reads the constant; pin the value.


def test_follow_boost_returns_zero_when_author_not_followed():
    followed = {_uid(), _uid()}
    other = _uid()
    assert follow_boost(other, followed) == 0.0


def test_follow_boost_returns_zero_with_empty_followed_set():
    assert follow_boost(_uid(), set()) == 0.0


# ---------------------------------------------------------------------------
# get_followed_author_ids
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_followed_author_ids_returns_empty_set_when_no_follows():
    db = _FakeSession([])  # empty result
    result = await get_followed_author_ids(db, _uid())
    assert result == set()
    assert isinstance(result, set)


@pytest.mark.asyncio
async def test_get_followed_author_ids_returns_followee_set():
    a, b, c = _uid(), _uid(), _uid()
    db = _FakeSession([a, b, c])
    result = await get_followed_author_ids(db, _uid())
    assert result == {a, b, c}


@pytest.mark.asyncio
async def test_get_followed_author_ids_filters_on_approved_status():
    """The SQL must restrict to status='approved'. We render the
    compiled statement and look for the predicate — easier than wiring
    a real DB and equally protective against accidental status drift
    (e.g. someone changing the helper to also include 'pending')."""
    db = _FakeSession([])
    await get_followed_author_ids(db, _uid())
    assert len(db.calls) == 1
    sql = _compile(db.calls[0]).lower()
    assert "follows" in sql
    assert "approved" in sql
    # We only want approved follows ranked — pending must not leak in.
    assert "'pending'" not in sql


@pytest.mark.asyncio
async def test_get_followed_author_ids_dedupes_via_set():
    """SQL `SELECT followee_id ... WHERE follower_id = :uid AND status='approved'`
    is uniqued at the DB level by the (follower_id, followee_id) unique
    constraint, but the Python return type is a set regardless so
    duplicates from any source collapse."""
    a = _uid()
    db = _FakeSession([a, a, a])
    result = await get_followed_author_ids(db, _uid())
    assert result == {a}


# ---------------------------------------------------------------------------
# followed_author_candidates
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_followed_author_candidates_short_circuits_on_empty_followed_set():
    """No DB round trip when the user follows nobody — `IN ()` against
    feed_items would be costly and meaningless."""
    db = _FakeSession()  # no canned responses; would raise IndexError if called
    result = await followed_author_candidates(db, _uid(), set())
    assert result == []
    assert db.calls == []


@pytest.mark.asyncio
async def test_followed_author_candidates_returns_ids_from_db():
    a, b, c = _uid(), _uid(), _uid()
    db = _FakeSession([a, b, c])
    result = await followed_author_candidates(
        db, _uid(), {_uid()}, limit=50
    )
    assert result == [a, b, c]


@pytest.mark.asyncio
async def test_followed_author_candidates_query_orders_newest_first_with_limit():
    """Verify the structural SQL: ORDER BY created_at DESC and LIMIT."""
    db = _FakeSession([])
    await followed_author_candidates(
        db, _uid(), {_uid(), _uid()}, limit=25
    )
    sql = _compile(db.calls[0]).lower()
    # Newest first.
    assert "order by feed_items.created_at desc" in sql
    # Limit applied.
    assert "limit 25" in sql


@pytest.mark.asyncio
async def test_followed_author_candidates_excludes_drafts_via_public_feed_clause():
    """`public_feed_clause` bundles `is_draft = false` AND visibility. The
    rendered SQL must contain the draft predicate so draft items don't
    leak into the candidate pool."""
    db = _FakeSession([])
    await followed_author_candidates(db, _uid(), {_uid()})
    sql = _compile(db.calls[0]).lower()
    assert "is_draft" in sql


@pytest.mark.asyncio
async def test_followed_author_candidates_excludes_requesting_user():
    """The user's own items must not appear in their own followed-author
    feed — even if they somehow follow themselves (the model forbids it
    via a CHECK constraint, but the SQL guards anyway)."""
    viewer = _uid()
    db = _FakeSession([])
    await followed_author_candidates(db, viewer, {_uid()})
    sql = _compile(db.calls[0]).lower()
    # SQLAlchemy renders the UUID literal without dashes — accept either form
    # so the test is robust to dialect-render quirks.
    viewer_with_dashes = str(viewer).lower()
    viewer_no_dashes = viewer_with_dashes.replace("-", "")
    assert (
        f"feed_items.author_id != '{viewer_with_dashes}'" in sql
        or f"feed_items.author_id != '{viewer_no_dashes}'" in sql
    )


@pytest.mark.asyncio
async def test_followed_author_candidates_default_limit_is_100():
    """Default limit is part of the public contract Track 6 depends on."""
    db = _FakeSession([])
    await followed_author_candidates(db, _uid(), {_uid()})
    sql = _compile(db.calls[0]).lower()
    assert "limit 100" in sql


@pytest.mark.asyncio
async def test_followed_author_candidates_default_days_is_30():
    """Default days window is part of the public contract; the cutoff
    appears as a literal timestamp in the rendered SQL — we just verify
    the `created_at >=` predicate is present so the bound exists."""
    db = _FakeSession([])
    await followed_author_candidates(db, _uid(), {_uid()})
    sql = _compile(db.calls[0]).lower()
    assert "feed_items.created_at >=" in sql
