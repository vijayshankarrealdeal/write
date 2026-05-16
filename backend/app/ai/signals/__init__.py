"""Ranking signal modules consumed by the recommendation pipeline.

Each submodule is a self-contained slice of the For You ranker:

* :mod:`follow`     — boosts items by authors the user follows; supplies
                      a candidate stratum of recent followed-author items.
* :mod:`seen`       — filters out items already shown via the impression
                      log so refreshes feel fresh.
* :mod:`completion` — turns finished / deep-scrolled reads into profile
                      weight (the strongest "this was good" signal in
                      the DB).
* :mod:`diversity`  — exponential decay on repeat-author scores; smoother
                      than a hard cap.

The recommendation engine imports the public symbols from this package
and composes them. Keeping signals isolated lets each be developed,
tuned, and tested without touching the others. See ``recommendation_new.md``
at the repo root for the build plan.
"""

from app.ai.signals.completion import (
    ABANDON_THRESHOLD,
    COMPLETION_WEIGHT,
    DEEP_SCROLL_THRESHOLD,
    DEEP_SCROLL_WEIGHT,
    CompletionSignals,
    apply_completion_to_profile,
    get_completion_signals,
)
from app.ai.signals.diversity import DiversityConfig, apply_author_diversity
from app.ai.signals.follow import (
    FOLLOW_BOOST,
    follow_boost,
    followed_author_candidates,
    get_followed_author_ids,
)
from app.ai.signals.seen import (
    DEFAULT_SEEN_WINDOW_DAYS,
    filter_seen,
    get_recently_seen_ids,
)

__all__ = [
    # follow
    "FOLLOW_BOOST",
    "follow_boost",
    "followed_author_candidates",
    "get_followed_author_ids",
    # seen
    "DEFAULT_SEEN_WINDOW_DAYS",
    "filter_seen",
    "get_recently_seen_ids",
    # completion
    "ABANDON_THRESHOLD",
    "COMPLETION_WEIGHT",
    "DEEP_SCROLL_THRESHOLD",
    "DEEP_SCROLL_WEIGHT",
    "CompletionSignals",
    "apply_completion_to_profile",
    "get_completion_signals",
    # diversity
    "DiversityConfig",
    "apply_author_diversity",
]
