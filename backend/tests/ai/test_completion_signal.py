"""Unit tests for the completion + deep-scroll signal helpers.

Following the DB-free pattern in `tests/test_recommendations_semantic.py`:
the pure functions (`apply_completion_to_profile`) are exercised
directly, and the async `get_completion_signals` helper uses a fake
`AsyncSession` whose `execute` returns the rows the test prescribes.
This keeps the suite fast and runnable without a Postgres instance.
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any

import pytest

from app.ai.signals.completion import (
    COMPLETION_WEIGHT,
    DEEP_SCROLL_THRESHOLD,
    DEEP_SCROLL_WEIGHT,
    CompletionSignals,
    apply_completion_to_profile,
    get_completion_signals,
)


# ---------------------------------------------------------------------------
# Fake AsyncSession infrastructure
# ---------------------------------------------------------------------------


@dataclass
class _FakeResult:
    rows: list[tuple]

    def all(self) -> list[tuple]:
        return self.rows


class _FakeSession:
    """Tiny stand-in for SQLAlchemy's AsyncSession.

    Stores a list of `(feed_item_id, scroll_position, completed)`
    tuples and yields them back from `execute(...)`. We don't validate
    the SQL — the helper only ever runs one shape of query.
    """

    def __init__(self, rows: list[tuple]) -> None:
        self.rows = rows
        self.last_stmt: Any = None

    async def execute(self, stmt: Any) -> _FakeResult:
        self.last_stmt = stmt
        return _FakeResult(self.rows)


# ---------------------------------------------------------------------------
# get_completion_signals
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_completion_signals_buckets_completed_and_deep_scroll():
    """Completed items go in `completed_item_ids`; non-completed rows
    with `scroll_position > DEEP_SCROLL_THRESHOLD` go in `deep_scroll_item_ids`."""
    user_id = uuid.uuid4()
    finished = uuid.uuid4()
    deep = uuid.uuid4()
    shallow = uuid.uuid4()
    barely_started = uuid.uuid4()

    db = _FakeSession(
        rows=[
            (finished, 0.95, True),
            (deep, 0.85, False),
            (shallow, 0.5, False),
            (barely_started, 0.1, False),
        ]
    )

    signals = await get_completion_signals(db, user_id)

    assert signals.completed_item_ids == [finished]
    assert signals.deep_scroll_item_ids == [deep]


@pytest.mark.asyncio
async def test_get_completion_signals_empty_returns_empty_buckets():
    """No reading_progress rows → empty signals (no exceptions)."""
    db = _FakeSession(rows=[])
    signals = await get_completion_signals(db, uuid.uuid4())
    assert signals.completed_item_ids == []
    assert signals.deep_scroll_item_ids == []


@pytest.mark.asyncio
async def test_get_completion_signals_completed_excluded_from_deep_scroll():
    """A row that is BOTH completed AND has `scroll_position > 0.7`
    must surface as completed only — never double-counted."""
    item_id = uuid.uuid4()
    db = _FakeSession(rows=[(item_id, 0.99, True)])

    signals = await get_completion_signals(db, uuid.uuid4())

    assert signals.completed_item_ids == [item_id]
    assert item_id not in signals.deep_scroll_item_ids
    assert signals.deep_scroll_item_ids == []


@pytest.mark.asyncio
async def test_get_completion_signals_handles_null_scroll_position():
    """`scroll_position` is nullable in the schema; rows with NULL
    should be treated as "neither deep-scroll nor completed"."""
    item_id = uuid.uuid4()
    db = _FakeSession(rows=[(item_id, None, False)])

    signals = await get_completion_signals(db, uuid.uuid4())

    assert signals.completed_item_ids == []
    assert signals.deep_scroll_item_ids == []


@pytest.mark.asyncio
async def test_get_completion_signals_threshold_is_strict_greater_than():
    """Boundary check: scroll_position exactly at the threshold does
    NOT count as deep-scroll (spec says `> 0.7`, not `>= 0.7`)."""
    at_threshold = uuid.uuid4()
    above_threshold = uuid.uuid4()
    db = _FakeSession(
        rows=[
            (at_threshold, DEEP_SCROLL_THRESHOLD, False),
            (above_threshold, DEEP_SCROLL_THRESHOLD + 0.001, False),
        ]
    )

    signals = await get_completion_signals(db, uuid.uuid4())

    assert at_threshold not in signals.deep_scroll_item_ids
    assert above_threshold in signals.deep_scroll_item_ids


# ---------------------------------------------------------------------------
# apply_completion_to_profile — pure-function tests
# ---------------------------------------------------------------------------


def test_empty_signals_leaves_dicts_unchanged():
    """A `CompletionSignals` with no ids should mutate nothing."""
    genres: dict[str, float] = {"fantasy": 1.0}
    tags: dict[str, float] = {"noir": 0.5}
    types: dict[str, float] = {"novella": 0.2}

    apply_completion_to_profile(
        genres, tags, types, CompletionSignals(), item_metadata={}
    )

    assert genres == {"fantasy": 1.0}
    assert tags == {"noir": 0.5}
    assert types == {"novella": 0.2}


def test_one_completed_item_bumps_each_genre_by_completion_weight():
    """A completed item with two genres → each genre gets +COMPLETION_WEIGHT."""
    item_id = uuid.uuid4()
    genres: dict[str, float] = {}
    tags: dict[str, float] = {}
    types: dict[str, float] = {}

    signals = CompletionSignals(completed_item_ids=[item_id])
    metadata = {
        item_id: {
            "genres": ["fantasy", "epic"],
            "tags": [],
            "writing_types": [],
        }
    }

    apply_completion_to_profile(genres, tags, types, signals, metadata)

    assert genres == {"fantasy": COMPLETION_WEIGHT, "epic": COMPLETION_WEIGHT}
    assert tags == {}
    assert types == {}


def test_one_completed_item_bumps_tags_and_writing_types_too():
    """All three buckets get the completion contribution."""
    item_id = uuid.uuid4()
    genres: dict[str, float] = {}
    tags: dict[str, float] = {}
    types: dict[str, float] = {}

    signals = CompletionSignals(completed_item_ids=[item_id])
    metadata = {
        item_id: {
            "genres": ["mystery"],
            "tags": ["slow-burn"],
            "writing_types": ["novel"],
        }
    }

    apply_completion_to_profile(genres, tags, types, signals, metadata)

    assert genres == {"mystery": COMPLETION_WEIGHT}
    assert tags == {"slow-burn": COMPLETION_WEIGHT}
    assert types == {"novel": COMPLETION_WEIGHT}


def test_one_deep_scroll_item_bumps_tag_by_deep_scroll_weight():
    """Deep-scroll uses the smaller DEEP_SCROLL_WEIGHT, not COMPLETION_WEIGHT."""
    item_id = uuid.uuid4()
    genres: dict[str, float] = {}
    tags: dict[str, float] = {}
    types: dict[str, float] = {}

    signals = CompletionSignals(deep_scroll_item_ids=[item_id])
    metadata = {
        item_id: {
            "genres": [],
            "tags": ["noir"],
            "writing_types": [],
        }
    }

    apply_completion_to_profile(genres, tags, types, signals, metadata)

    assert tags == {"noir": DEEP_SCROLL_WEIGHT}
    assert genres == {}
    assert types == {}


def test_missing_metadata_silently_skipped():
    """Item present in signals but absent from item_metadata → no error,
    no mutation. Real-world: the FeedItem may have been deleted since
    the user read it."""
    known = uuid.uuid4()
    ghost = uuid.uuid4()
    genres: dict[str, float] = {}
    tags: dict[str, float] = {}
    types: dict[str, float] = {}

    signals = CompletionSignals(
        completed_item_ids=[known, ghost],
        deep_scroll_item_ids=[ghost],
    )
    metadata = {
        known: {"genres": ["sci-fi"], "tags": [], "writing_types": []},
    }

    apply_completion_to_profile(genres, tags, types, signals, metadata)

    # Only the known item contributed.
    assert genres == {"sci-fi": COMPLETION_WEIGHT}
    assert tags == {}
    assert types == {}


def test_completed_and_deep_scroll_signals_are_additive_when_distinct():
    """One completed + one deep-scroll on different items → both contributions
    land. (Same-item double-counting is prevented upstream in
    `get_completion_signals`, but the function should still cope if a caller
    constructs CompletionSignals manually with disjoint lists.)"""
    completed_id = uuid.uuid4()
    deep_id = uuid.uuid4()

    genres: dict[str, float] = {}
    tags: dict[str, float] = {}
    types: dict[str, float] = {}

    signals = CompletionSignals(
        completed_item_ids=[completed_id],
        deep_scroll_item_ids=[deep_id],
    )
    metadata = {
        completed_id: {"genres": ["fantasy"], "tags": [], "writing_types": []},
        deep_id: {"genres": ["fantasy"], "tags": [], "writing_types": []},
    }

    apply_completion_to_profile(genres, tags, types, signals, metadata)

    assert genres == {"fantasy": COMPLETION_WEIGHT + DEEP_SCROLL_WEIGHT}


def test_apply_completion_accumulates_into_preexisting_weights():
    """The function adds to whatever's already there — it doesn't reset."""
    item_id = uuid.uuid4()
    genres: dict[str, float] = {"fantasy": 5.0, "horror": 0.5}
    tags: dict[str, float] = {}
    types: dict[str, float] = {}

    signals = CompletionSignals(completed_item_ids=[item_id])
    metadata = {
        item_id: {"genres": ["fantasy"], "tags": [], "writing_types": []},
    }

    apply_completion_to_profile(genres, tags, types, signals, metadata)

    assert genres["fantasy"] == 5.0 + COMPLETION_WEIGHT
    assert genres["horror"] == 0.5  # untouched


def test_missing_keys_in_metadata_dict_are_safe():
    """If a metadata entry omits e.g. "tags", we shouldn't crash — just
    skip that bucket for that item."""
    item_id = uuid.uuid4()
    genres: dict[str, float] = {}
    tags: dict[str, float] = {}
    types: dict[str, float] = {}

    signals = CompletionSignals(completed_item_ids=[item_id])
    metadata = {item_id: {"genres": ["fantasy"]}}  # no "tags", no "writing_types"

    apply_completion_to_profile(genres, tags, types, signals, metadata)

    assert genres == {"fantasy": COMPLETION_WEIGHT}
    assert tags == {}
    assert types == {}


# ---------------------------------------------------------------------------
# Integration of the two — verify the "no double-counting" promise from
# the spec end-to-end (the same item ending up in BOTH buckets would
# inflate its weight by COMPLETION_WEIGHT + DEEP_SCROLL_WEIGHT, which is
# exactly the bug we want guarded against).
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_no_double_counting_for_completed_with_high_scroll():
    """End-to-end: a single ReadingProgress row that is completed AND
    has scroll_position > 0.7 must contribute COMPLETION_WEIGHT once,
    NOT COMPLETION_WEIGHT + DEEP_SCROLL_WEIGHT."""
    item_id = uuid.uuid4()
    db = _FakeSession(rows=[(item_id, 0.99, True)])

    signals = await get_completion_signals(db, uuid.uuid4())

    genres: dict[str, float] = {}
    tags: dict[str, float] = {}
    types: dict[str, float] = {}
    metadata = {item_id: {"genres": ["fantasy"], "tags": [], "writing_types": []}}

    apply_completion_to_profile(genres, tags, types, signals, metadata)

    # COMPLETION_WEIGHT only — no extra DEEP_SCROLL_WEIGHT added.
    assert genres == {"fantasy": COMPLETION_WEIGHT}
