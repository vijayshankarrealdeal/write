"""Exponential author-diversity scorer (Track 4 of ``recommendation_new.md``).

The legacy diversification pass in ``app.ai.recommendation._diversify`` enforces
a hard per-author cap (default 2 items). That's binary — once you hit the cap
the author vanishes entirely from the slate. Twitter's open-source ranker uses
a smoother exponential decay instead: every additional appearance from the same
author multiplies its score by ``decay ** index``, blended with a small
``floor`` so even very prolific authors retain *some* presence. This module
ports that heuristic as a pure function so Track 6 can drop in a one-line
replacement for ``_diversify``.

Public surface (consumed by ``app.ai.recommendation`` after Track 6 wires it in):

* :class:`DiversityConfig` — frozen dataclass with sane defaults and validation.
* :func:`apply_author_diversity` — pure scorer that re-ranks a scored list.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from uuid import UUID


@dataclass(frozen=True)
class DiversityConfig:
    """Knobs for :func:`apply_author_diversity`.

    The multiplier applied to the *n*-th appearance of a given author (0-indexed)
    is ``floor + (1 - floor) * decay ** n``. With the defaults below:

    * position 0 → ``1.0`` (untouched)
    * position 1 → ``0.64``
    * position 2 → ``0.424``
    * …
    * position ∞ → ``floor`` (≈ 0.1)

    Attributes:
        decay: Base of the exponential demotion. Must lie strictly inside
            ``(0, 1)``. Smaller values = harsher demotion of repeat appearances.
        floor: Asymptotic minimum multiplier. Must lie in ``[0, 1)``. Guarantees
            a popular author is never *completely* silenced.
    """

    decay: float = 0.6
    floor: float = 0.1

    def __post_init__(self) -> None:
        # Reject configurations that would make the math meaningless. We use
        # ``ValueError`` so a config typo surfaces at construction time rather
        # than as a silent ranking bug.
        if not 0.0 < self.decay < 1.0:
            raise ValueError(f"decay must be in (0,1), got {self.decay}")
        if not 0.0 <= self.floor < 1.0:
            raise ValueError(f"floor must be in [0,1), got {self.floor}")


def apply_author_diversity(
    scored: list[tuple[UUID, float, UUID]],
    config: DiversityConfig = DiversityConfig(),
) -> list[tuple[UUID, float, UUID]]:
    """Demote repeat appearances of the same author with an exponential decay.

    Walks ``scored`` in input order (callers pass it sorted DESC by score),
    counts how many times each ``author_id`` has been seen so far, and
    multiplies the item's score by ``floor + (1 - floor) * decay ** index``.
    Returns a *new* list re-sorted by the adjusted score DESC — the input is
    not mutated.

    Args:
        scored: Triples of ``(item_id, score, author_id)`` already sorted by
            ``score`` descending. ``author_id`` is whatever the caller uses to
            group items — typically ``FeedItem.author_id``.
        config: Decay/floor knobs. Defaults give a moderate Twitter-style
            demotion (see :class:`DiversityConfig`).

    Returns:
        A new list of the same triples with each ``score`` replaced by its
        diversity-adjusted value, sorted by the new score descending.
    """
    if not scored:
        return []

    # ``defaultdict(int)`` is the simplest way to track the per-author counter;
    # the first appearance gets index 0 (multiplier = 1.0), and we increment
    # only *after* applying the multiplier so each author's first item is
    # always untouched.
    counts: dict[UUID, int] = defaultdict(int)
    one_minus_floor = 1.0 - config.floor

    adjusted: list[tuple[UUID, float, UUID]] = []
    for item_id, score, author_id in scored:
        index = counts[author_id]
        multiplier = config.floor + one_minus_floor * (config.decay**index)
        adjusted.append((item_id, score * multiplier, author_id))
        counts[author_id] = index + 1

    # Re-sort by the *adjusted* score so demoted repeat-author items naturally
    # interleave with fresh authors further down the original list.
    adjusted.sort(key=lambda triple: triple[1], reverse=True)
    return adjusted
