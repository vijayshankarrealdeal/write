"""Ranking signal modules consumed by the recommendation pipeline.

Each Track in `recommendation_new.md` lands as its own self-contained
module here. Track 6 (the integration pass on `recommendation.py`)
imports the public symbols from this package; nothing in
`recommendation.py` reaches inside individual submodules.
"""
from app.ai.signals.follow import (
    FOLLOW_BOOST,
    follow_boost,
    followed_author_candidates,
    get_followed_author_ids,
)

__all__ = [
    "FOLLOW_BOOST",
    "follow_boost",
    "followed_author_candidates",
    "get_followed_author_ids",
]
