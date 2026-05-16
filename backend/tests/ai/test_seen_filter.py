"""Tests for the already-shown dedup helpers.

Two layers:

* ``filter_seen`` is a pure function — exercised with plain UUID lists
  and no async machinery at all.
* ``get_recently_seen_ids`` is async + DB-bound, but the query is so
  small (one ``SELECT DISTINCT`` against ``recommendation_events``)
  that we don't need a real Postgres. A lightweight in-memory fake
  ``AsyncSession`` that interprets the SQLAlchemy ``Select`` against a
  local list of ``RecommendationEvent``-shaped rows is enough to pin
  the contract: impressions are included, clicks are not, and the
  ``days`` window is honoured.

Why not testcontainers? The integration suite (see
``test_analytics_integration.py``) already exercises the live DB path
for the broader analytics layer; the marginal value of also booting
Postgres for this trivial query is low and would force every CI run
to pull a Docker image. The in-memory fake is precise about what it
asserts: it walks the SQLAlchemy ``Select`` AST for the exact
``where`` clauses the production code emits, so a behavioural drift
in either ``user_id`` matching or the ``event_type`` filter would
surface here as a regression rather than as a silent pass.
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import pytest

from app.ai.signals.seen import (
    DEFAULT_SEEN_WINDOW_DAYS,
    filter_seen,
    get_recently_seen_ids,
)


# ---------------------------------------------------------------------------
# filter_seen — pure function
# ---------------------------------------------------------------------------


def _ids(n: int) -> list[uuid.UUID]:
    return [uuid.uuid4() for _ in range(n)]


def test_filter_seen_drops_seen_ids():
    a, b, c = _ids(3)
    assert filter_seen([a, b, c], {b}) == [a, c]


def test_filter_seen_preserves_order():
    a, b, c, d = _ids(4)
    # b and d are "seen" — the surviving ids must keep their original
    # ranking, not reshuffle.
    assert filter_seen([a, b, c, d], {b, d}) == [a, c]


def test_filter_seen_empty_seen_returns_copy():
    a, b = _ids(2)
    candidates = [a, b]
    out = filter_seen(candidates, set())
    assert out == [a, b]
    # New list — mutating it must not touch the caller's input.
    out.append(uuid.uuid4())
    assert candidates == [a, b]


def test_filter_seen_empty_candidates_returns_empty():
    assert filter_seen([], {uuid.uuid4()}) == []


def test_filter_seen_keep_top_n_preserves_evergreens():
    a, b, c, d, e = _ids(5)
    # All five are "seen", but the top 2 slots are protected — they
    # represent the evergreens we still want surfaced.
    out = filter_seen([a, b, c, d, e], {a, b, c, d, e}, keep_top_n=2)
    assert out == [a, b]


def test_filter_seen_keep_top_n_does_not_revive_below_threshold():
    a, b, c, d = _ids(4)
    # keep_top_n=1 protects only the first slot; everything else seen
    # must still drop.
    out = filter_seen([a, b, c, d], {a, b, c}, keep_top_n=1)
    assert out == [a, d]


def test_filter_seen_keep_top_n_zero_is_default_behaviour():
    a, b, c = _ids(3)
    assert filter_seen([a, b, c], {a}) == filter_seen(
        [a, b, c], {a}, keep_top_n=0
    )


def test_filter_seen_negative_keep_top_n_treated_as_zero():
    a, b = _ids(2)
    # Defensive: a negative value shouldn't be interpreted as "protect
    # everything except the last N" or any other clever thing — just
    # clamp to 0.
    assert filter_seen([a, b], {a}, keep_top_n=-3) == [b]


def test_filter_seen_no_overlap_returns_full_list():
    a, b, c = _ids(3)
    assert filter_seen([a, b, c], {uuid.uuid4()}) == [a, b, c]


# ---------------------------------------------------------------------------
# get_recently_seen_ids — async + DB-bound, exercised with an in-memory fake
# ---------------------------------------------------------------------------


@dataclass
class _Row:
    """Stand-in for a ``RecommendationEvent`` row, just enough surface
    for the fake session to evaluate the production WHERE clause."""

    user_id: uuid.UUID
    event_type: str
    feed_item_id: uuid.UUID
    created_at: datetime


class _FakeScalarsResult:
    def __init__(self, values: list[uuid.UUID]) -> None:
        self._values = values

    def all(self) -> list[uuid.UUID]:
        return list(self._values)


class _FakeResult:
    def __init__(self, values: list[uuid.UUID]) -> None:
        self._values = values

    def scalars(self) -> _FakeScalarsResult:
        return _FakeScalarsResult(self._values)


class _FakeAsyncSession:
    """Minimal stand-in for ``AsyncSession`` that interprets the
    SQLAlchemy ``Select`` our module builds.

    We pull the ``where`` clauses off the compiled select, then walk
    the local rows applying each predicate. This keeps the test
    independent of Postgres while still asserting the production query
    shape — if someone drops ``event_type == 'impression'`` from the
    where chain, the click-only fixture below will start leaking through
    and the test will fail.
    """

    def __init__(self, rows: list[_Row]) -> None:
        self.rows = rows
        self.last_stmt = None

    async def execute(self, stmt):
        self.last_stmt = stmt
        clauses = list(stmt.whereclause.clauses) if stmt.whereclause is not None else []
        out: list[uuid.UUID] = []
        for row in self.rows:
            if all(_eval_clause(c, row) for c in clauses):
                out.append(row.feed_item_id)
        # Production uses .distinct() — mirror that.
        seen: set[uuid.UUID] = set()
        deduped: list[uuid.UUID] = []
        for fid in out:
            if fid in seen:
                continue
            seen.add(fid)
            deduped.append(fid)
        return _FakeResult(deduped)


def _eval_clause(clause, row: _Row) -> bool:
    """Tiny clause evaluator covering exactly the operators the
    production query uses: ``==`` between a column and a literal, and
    ``>`` between a column and a datetime literal."""
    op = clause.operator.__name__  # 'eq' / 'gt'
    col_name = clause.left.key
    rhs = clause.right.value
    actual = getattr(row, col_name)
    if op == "eq":
        return actual == rhs
    if op == "gt":
        return actual > rhs
    raise AssertionError(f"unexpected operator in seen filter query: {op!r}")


@pytest.mark.asyncio
async def test_get_recently_seen_ids_no_events_returns_empty_set():
    user_id = uuid.uuid4()
    session = _FakeAsyncSession(rows=[])
    out = await get_recently_seen_ids(session, user_id)
    assert out == set()


@pytest.mark.asyncio
async def test_get_recently_seen_ids_returns_impression_ids():
    user_id = uuid.uuid4()
    item_a, item_b = uuid.uuid4(), uuid.uuid4()
    now = datetime.now(UTC)
    rows = [
        _Row(user_id, "impression", item_a, now - timedelta(hours=1)),
        _Row(user_id, "impression", item_b, now - timedelta(hours=2)),
    ]
    session = _FakeAsyncSession(rows=rows)
    out = await get_recently_seen_ids(session, user_id)
    assert out == {item_a, item_b}


@pytest.mark.asyncio
async def test_get_recently_seen_ids_ignores_click_events():
    """Click events are intentionally excluded — engaged content is
    safe to re-surface eventually, so it must not poison the seen set."""
    user_id = uuid.uuid4()
    item_a, item_b = uuid.uuid4(), uuid.uuid4()
    now = datetime.now(UTC)
    rows = [
        _Row(user_id, "impression", item_a, now - timedelta(hours=1)),
        _Row(user_id, "click", item_b, now - timedelta(hours=1)),
    ]
    session = _FakeAsyncSession(rows=rows)
    out = await get_recently_seen_ids(session, user_id)
    assert out == {item_a}
    assert item_b not in out


@pytest.mark.asyncio
async def test_get_recently_seen_ids_respects_days_window():
    user_id = uuid.uuid4()
    recent, stale = uuid.uuid4(), uuid.uuid4()
    now = datetime.now(UTC)
    rows = [
        _Row(user_id, "impression", recent, now - timedelta(days=2)),
        # Outside the default 10-day window.
        _Row(user_id, "impression", stale, now - timedelta(days=42)),
    ]
    session = _FakeAsyncSession(rows=rows)
    out = await get_recently_seen_ids(session, user_id)
    assert out == {recent}


@pytest.mark.asyncio
async def test_get_recently_seen_ids_ignores_other_users():
    me, them = uuid.uuid4(), uuid.uuid4()
    mine, theirs = uuid.uuid4(), uuid.uuid4()
    now = datetime.now(UTC)
    rows = [
        _Row(me, "impression", mine, now - timedelta(hours=1)),
        _Row(them, "impression", theirs, now - timedelta(hours=1)),
    ]
    session = _FakeAsyncSession(rows=rows)
    out = await get_recently_seen_ids(session, me)
    assert out == {mine}


@pytest.mark.asyncio
async def test_get_recently_seen_ids_custom_days_widens_window():
    user_id = uuid.uuid4()
    item_old = uuid.uuid4()
    now = datetime.now(UTC)
    rows = [
        _Row(user_id, "impression", item_old, now - timedelta(days=20)),
    ]
    session = _FakeAsyncSession(rows=rows)
    # Default window misses it.
    assert await get_recently_seen_ids(session, user_id) == set()
    # Custom 30-day window catches it.
    assert await get_recently_seen_ids(session, user_id, days=30) == {item_old}


@pytest.mark.asyncio
async def test_get_recently_seen_ids_zero_days_short_circuits():
    """Caller can disable the filter without a DB round-trip by passing
    ``days=0`` (or negative). Useful for kill-switches in config."""
    user_id = uuid.uuid4()
    item = uuid.uuid4()
    now = datetime.now(UTC)
    rows = [_Row(user_id, "impression", item, now)]
    session = _FakeAsyncSession(rows=rows)
    out = await get_recently_seen_ids(session, user_id, days=0)
    assert out == set()
    assert session.last_stmt is None, "days<=0 must not hit the database"


def test_default_seen_window_constant_is_sane():
    """Locked in by review — a runaway change here would silently shift
    every personalised feed. 10 days is the tuned default."""
    assert DEFAULT_SEEN_WINDOW_DAYS == 10
