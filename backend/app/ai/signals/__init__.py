"""Signal modules used by the recommendation pipeline.

Each signal is a self-contained submodule with a small public surface;
the recommendation engine imports the exported helpers and composes
them. Keeping the signals isolated lets parallel work proceed without
collisions on ``recommendation.py``.
"""

from app.ai.signals.seen import (
    DEFAULT_SEEN_WINDOW_DAYS,
    filter_seen,
    get_recently_seen_ids,
)


__all__ = [
    "DEFAULT_SEEN_WINDOW_DAYS",
    "filter_seen",
    "get_recently_seen_ids",
]
