"""Per-signal helper modules consumed by `app.ai.recommendation`.

Each module in this package exposes a small, pure-ish interface for a
single ranking signal (follow graph, already-seen filter, completion,
diversity reshuffle). The coordinator stitches them into the main
scoring pipeline; the modules themselves stay decoupled so they can be
built and tested independently.

See `recommendation_new.md` at the repo root for the full plan.
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

__all__ = [
    "ABANDON_THRESHOLD",
    "COMPLETION_WEIGHT",
    "DEEP_SCROLL_THRESHOLD",
    "DEEP_SCROLL_WEIGHT",
    "CompletionSignals",
    "apply_completion_to_profile",
    "get_completion_signals",
]
