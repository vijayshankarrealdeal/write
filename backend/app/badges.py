"""Reader and writer tier badges.

Two parallel progressions so non-writers still see motion.

# Anti-gaming
Writer tiers don't reward raw publish count. Each non-trivial tier
requires a *minimum ratio* of received-engagement-per-post and at
least one independent friction signal (comments or followers), so a
user can't reach Author or Master by spam-publishing. Reader tiers
require depth signals (highlights, comments, completed reads) plus
streak (active reading days), so opening tabs is not the same as
finishing them.

# Top-tier override
INKSPACE_TOP_TIER_EMAILS bypass all gates and pin to the top tier of
both tracks — used for the platform's own first-party account so it
always reads as authoritative.

Pure functions over already-aggregated counts — caller computes the
counts (or pulls them from the existing subqueries on `PublicUser`)
and asks `compute_writer_tier(...)` / `compute_reader_tier(...)` for
the badge dict to attach to the response.
"""
from __future__ import annotations

from typing import TypedDict


class Badge(TypedDict):
    track: str          # 'reader' | 'writer'
    tier: int           # 0..4
    slug: str           # e.g. 'storyteller'
    label: str          # e.g. 'Storyteller'
    color: str          # hex like '#A855F7' — UI accent for the chip
    icon: str           # named icon key the Flutter side maps to a glyph
    next_label: str | None       # next tier name, or None at max
    next_progress: float | None  # 0.0..1.0 toward next tier, or None at max


# Accounts that bypass tier gates and pin to the top of both tracks.
# Add by string match, lowercased — used for the platform's own
# first-party account so its presence on the platform always reads as
# authoritative.
INKSPACE_TOP_TIER_EMAILS: frozenset[str] = frozenset({
    "inkspace@inkspacex.com",
})


# Each tuple: (slug, label, color, icon, requirements_dict)
# Requirements are AND-ed; the highest tier whose requirements are all
# met wins.
#
# `min_likes_per_post` and `min_comments_per_post` enforce *quality
# density* — they only kick in once `published >= 5`, so they don't
# block early authors but do stop someone publishing 100 empty posts
# from reaching Master. The ratio is computed before the lookup and
# passed into `counts` by `compute_writer_tier`.
_WRITER_TIERS: list[tuple[str, str, str, str, dict[str, int]]] = [
    ("novice",       "Novice",       "#94A3B8", "feather",  {"published": 0}),
    ("contributor",  "Contributor",  "#22C55E", "leaf",     {"published": 1, "likes_received": 5}),
    ("storyteller",  "Storyteller",  "#3B82F6", "book",     {
        "published": 5, "likes_received": 50, "comments_received": 10,
        "min_likes_per_post": 5,
    }),
    ("author",       "Author",       "#A855F7", "quill",    {
        "published": 15, "likes_received": 500, "comments_received": 75,
        "followers": 25, "min_likes_per_post": 15,
    }),
    ("master",       "Master",       "#F59E0B", "crown",    {
        "published": 50, "likes_received": 5000, "comments_received": 500,
        "followers": 250, "min_likes_per_post": 40,
    }),
]

# Reader tier requirements add `comments_authored` (thoughtful
# participation, not silent scrolling) and `active_reading_days`
# (consistency over time — opening 100 articles in one weekend isn't
# the same as reading every week for months).
_READER_TIERS: list[tuple[str, str, str, str, dict[str, int]]] = [
    ("curious",   "Curious",   "#94A3B8", "spark",      {"reads_completed": 0}),
    ("reader",    "Reader",    "#22C55E", "bookmark",   {"reads_completed": 5}),
    ("bookworm",  "Bookworm",  "#3B82F6", "books",      {
        "reads_completed": 25, "highlights": 5,
        "comments_authored": 3, "active_reading_days": 14,
    }),
    ("scholar",   "Scholar",   "#A855F7", "graduation", {
        "reads_completed": 100, "highlights": 25,
        "comments_authored": 15, "active_reading_days": 60,
    }),
    ("sage",      "Sage",      "#F59E0B", "owl",        {
        "reads_completed": 500, "highlights": 100,
        "comments_authored": 50, "active_reading_days": 180,
    }),
]


def _top_tier_badge(tiers: list[tuple[str, str, str, str, dict[str, int]]], track: str) -> "Badge":
    slug, label, color, icon, _ = tiers[-1]
    return Badge(
        track=track,
        tier=len(tiers) - 1,
        slug=slug,
        label=label,
        color=color,
        icon=icon,
        next_label=None,
        next_progress=None,
    )


def _resolve_tier(
    tiers: list[tuple[str, str, str, str, dict[str, int]]],
    counts: dict[str, int],
) -> tuple[int, dict[str, int] | None]:
    """Return (tier_index, next_tier_requirements_or_None).

    Walks tiers in order; the highest one with all requirements satisfied
    wins. Returns the *next* tier's requirements alongside so the caller
    can render a "X / Y" progress hint.
    """
    achieved = 0
    for idx, (_, _, _, _, reqs) in enumerate(tiers):
        if all(counts.get(k, 0) >= v for k, v in reqs.items()):
            achieved = idx
    next_reqs = tiers[achieved + 1][4] if achieved + 1 < len(tiers) else None
    return achieved, next_reqs


def _progress_to_next(counts: dict[str, int], next_reqs: dict[str, int] | None) -> float | None:
    """Coarse 0..1 progress to the next tier — slowest dimension wins so
    the bar reflects the gating constraint, not the easiest one."""
    if next_reqs is None:
        return None
    ratios: list[float] = []
    for k, target in next_reqs.items():
        if target <= 0:
            continue
        ratios.append(min(1.0, counts.get(k, 0) / target))
    if not ratios:
        return None
    return min(ratios)


def is_top_tier_email(email: str | None) -> bool:
    return bool(email) and email.lower() in INKSPACE_TOP_TIER_EMAILS


def compute_writer_tier(
    *,
    published: int,
    likes_received: int,
    followers: int,
    comments_received: int = 0,
    email: str | None = None,
) -> Badge:
    if is_top_tier_email(email):
        return _top_tier_badge(_WRITER_TIERS, "writer")
    # Quality-density signal — likes/post computed once and matched in
    # the same per-tier requirements check. Stops a 100-post empty
    # author from sliding into Master on raw count alone.
    likes_per_post = (likes_received // published) if published > 0 else 0
    comments_per_post = (comments_received // published) if published > 0 else 0
    counts = {
        "published": published,
        "likes_received": likes_received,
        "followers": followers,
        "comments_received": comments_received,
        "min_likes_per_post": likes_per_post,
        "min_comments_per_post": comments_per_post,
    }
    idx, next_reqs = _resolve_tier(_WRITER_TIERS, counts)
    slug, label, color, icon, _ = _WRITER_TIERS[idx]
    next_label = _WRITER_TIERS[idx + 1][1] if idx + 1 < len(_WRITER_TIERS) else None
    return Badge(
        track="writer",
        tier=idx,
        slug=slug,
        label=label,
        color=color,
        icon=icon,
        next_label=next_label,
        next_progress=_progress_to_next(counts, next_reqs),
    )


def compute_reader_tier(
    *,
    reads_completed: int,
    highlights: int,
    comments_authored: int = 0,
    active_reading_days: int = 0,
    email: str | None = None,
) -> Badge:
    if is_top_tier_email(email):
        return _top_tier_badge(_READER_TIERS, "reader")
    counts = {
        "reads_completed": reads_completed,
        "highlights": highlights,
        "comments_authored": comments_authored,
        "active_reading_days": active_reading_days,
    }
    idx, next_reqs = _resolve_tier(_READER_TIERS, counts)
    slug, label, color, icon, _ = _READER_TIERS[idx]
    next_label = _READER_TIERS[idx + 1][1] if idx + 1 < len(_READER_TIERS) else None
    return Badge(
        track="reader",
        tier=idx,
        slug=slug,
        label=label,
        color=color,
        icon=icon,
        next_label=next_label,
        next_progress=_progress_to_next(counts, next_reqs),
    )
