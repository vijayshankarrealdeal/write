"""Completion + deep-scroll signal helpers — Track 3 of recommendation_new.md.

Hypothesis: `ReadingProgress.completed=True` is the strongest "this was
good" signal in the database — finishing a book is rarer and stronger
evidence of fit than a like. The existing profile builder in
`app.ai.recommendation` reads `ReadingProgress` rows but does not give
completion its own weight contribution above the generic "read it"
bucket. This module surfaces two clean signals (completed, deep-scroll)
that the integrator wires into the aggregator without rewriting it.

Abandoned items (scroll_position < ABANDON_THRESHOLD) are intentionally
NOT surfaced here — the existing aggregator already applies an abandon
penalty and we don't want to double-count.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.reading_progress import ReadingProgress


# ---------------------------------------------------------------------------
# Weights — additive on top of `recommendation._aggregate_profile`.
# Calibrated against the existing scale (like=+2.0, favorite=+3.0,
# highlight=+2.5, save=+1.5, abandon=-1.5). Completion ties with favorite
# on purpose: finishing a book is at least as strong as bookmarking it.
# ---------------------------------------------------------------------------

COMPLETION_WEIGHT: float = 3.0
DEEP_SCROLL_WEIGHT: float = 1.5

# `scroll_position > DEEP_SCROLL_THRESHOLD` and not completed → "deep scroll".
DEEP_SCROLL_THRESHOLD: float = 0.7

# `scroll_position < ABANDON_THRESHOLD` is the "abandoned" bucket. We
# track it for cross-reference but deliberately don't apply a penalty
# from this module — the existing aggregator already does. Kept here so
# the integrator has a single source of truth for the threshold.
ABANDON_THRESHOLD: float = 0.25


@dataclass(frozen=True)
class CompletionSignals:
    """Bucketed ReadingProgress signals for one user."""

    completed_item_ids: list[UUID] = field(default_factory=list)
    # `> DEEP_SCROLL_THRESHOLD` and NOT completed (no double-counting).
    deep_scroll_item_ids: list[UUID] = field(default_factory=list)

    # Note: abandoned items (`scroll_position < ABANDON_THRESHOLD`) are
    # already penalised by `recommendation._aggregate_profile`. We
    # deliberately don't expose them here — surfacing them would invite
    # the caller to double-apply the penalty.


async def get_completion_signals(db: AsyncSession, user_id: UUID) -> CompletionSignals:
    """Pull the user's ReadingProgress rows and bucket by progress depth.

    One round trip; bucketing happens in Python so the call stays cheap
    even for power readers (a few hundred rows at most).
    """
    stmt = select(
        ReadingProgress.feed_item_id,
        ReadingProgress.scroll_position,
        ReadingProgress.completed,
    ).where(ReadingProgress.user_id == user_id)

    rows = (await db.execute(stmt)).all()

    completed: list[UUID] = []
    deep_scroll: list[UUID] = []

    for feed_item_id, scroll_position, completed_flag in rows:
        if completed_flag:
            completed.append(feed_item_id)
            # Completed takes precedence; never add to deep_scroll too.
            continue
        if scroll_position is not None and scroll_position > DEEP_SCROLL_THRESHOLD:
            deep_scroll.append(feed_item_id)

    return CompletionSignals(
        completed_item_ids=completed,
        deep_scroll_item_ids=deep_scroll,
    )


def apply_completion_to_profile(
    genre_weights: dict[str, float],
    tag_weights: dict[str, float],
    type_weights: dict[str, float],
    signals: CompletionSignals,
    item_metadata: dict[UUID, dict],
) -> None:
    """Add completion / deep-scroll contributions to the three weight dicts.

    Mutates the dicts in place — chosen deliberately to mirror how
    `_aggregate_profile` accumulates into `Counter`s.

    Parameters
    ----------
    genre_weights, tag_weights, type_weights:
        The user's running preference weights keyed by genre/tag/type.
    signals:
        Output of `get_completion_signals`.
    item_metadata:
        Map of `feed_item_id → {"genres": [...], "tags": [...],
        "writing_types": [...]}`. The integrator builds this once per
        request from the FeedItems it already loaded — we don't query
        here. Items missing from the map are silently skipped (the
        FeedItem may have been deleted since the user read it).
    """
    for item_id in signals.completed_item_ids:
        meta = item_metadata.get(item_id)
        if not meta:
            continue
        _bump(genre_weights, meta.get("genres"), COMPLETION_WEIGHT)
        _bump(tag_weights, meta.get("tags"), COMPLETION_WEIGHT)
        _bump(type_weights, meta.get("writing_types"), COMPLETION_WEIGHT)

    for item_id in signals.deep_scroll_item_ids:
        meta = item_metadata.get(item_id)
        if not meta:
            continue
        _bump(genre_weights, meta.get("genres"), DEEP_SCROLL_WEIGHT)
        _bump(tag_weights, meta.get("tags"), DEEP_SCROLL_WEIGHT)
        _bump(type_weights, meta.get("writing_types"), DEEP_SCROLL_WEIGHT)


def _bump(weights: dict[str, float], keys: list[str] | None, delta: float) -> None:
    """Add `delta` to each `key` in `weights`. Safe on None / empty input.

    `Counter` and plain `dict` both accept this — the integrator can
    pass either without surprises.
    """
    if not keys:
        return
    for key in keys:
        # `dict.get(..., 0)` works for both plain dicts and Counters.
        weights[key] = weights.get(key, 0.0) + delta
