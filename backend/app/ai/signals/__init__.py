"""Pure-function signal modules for the recommendation pipeline.

Each submodule exposes self-contained scorers / filters that the main
``app.ai.recommendation`` module wires into its scoring + diversification
passes. Keeping these out of ``recommendation.py`` lets multiple agents
build signals in parallel without merge conflicts (see
``recommendation_new.md`` at the repo root for the full plan).
"""

from app.ai.signals.diversity import DiversityConfig, apply_author_diversity

__all__ = [
    "DiversityConfig",
    "apply_author_diversity",
]
