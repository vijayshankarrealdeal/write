"""Recommendation engine — personalised feed for each user.

Strategy
--------
1. **Collect signals** from the user's behaviour:
   - genres / tags / writing_types of items they liked, read, saved, favorited, highlighted
   - reading-progress completion rates (finished vs abandoned)
   - recency of interactions

2. **Build a preference profile** (genre weights, tag weights, type weights).

3. **Score every candidate feed item** against that profile (weighted overlap)
   plus a popularity / freshness blend.

4. **LLM re-rank** (optional) — pass the top-N candidates through a Pydantic-AI
   agent that returns an ordered list with short "why you'll like this" reasons,
   taking the user's reading history into account.
"""

from __future__ import annotations

import math
from collections import Counter
from dataclasses import dataclass, field
from datetime import UTC, datetime
from uuid import UUID

from pydantic import BaseModel
from pydantic_ai import Agent
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.client import model
from app.models.feed_item import FeedItem
from app.models.highlight import Highlight
from app.models.reading_progress import ReadingProgress
from app.models.user import User


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class UserProfile:
    """Aggregated preference profile built from user behaviour."""
    genre_weights: Counter = field(default_factory=Counter)
    tag_weights: Counter = field(default_factory=Counter)
    type_weights: Counter = field(default_factory=Counter)
    liked_ids: set[str] = field(default_factory=set)
    read_ids: set[str] = field(default_factory=set)
    saved_ids: set[str] = field(default_factory=set)
    favorite_ids: set[str] = field(default_factory=set)
    highlighted_item_ids: set[str] = field(default_factory=set)
    completed_ids: set[str] = field(default_factory=set)
    abandoned_ids: set[str] = field(default_factory=set)


class ScoredItem(BaseModel):
    feed_item_id: str
    title: str | None
    author: str | None
    genres: list[str]
    tags: list[str]
    score: float
    reason: str | None = None


class RecommendationResult(BaseModel):
    items: list[ScoredItem]
    profile_summary: ProfileSummary | None = None


class ProfileSummary(BaseModel):
    top_genres: list[str]
    top_tags: list[str]
    top_types: list[str]
    total_reads: int
    total_likes: int


# ---------------------------------------------------------------------------
# Fix forward ref (ProfileSummary used before definition in RecommendationResult)
# ---------------------------------------------------------------------------
RecommendationResult.model_rebuild()


# ---------------------------------------------------------------------------
# 1. Build user preference profile
# ---------------------------------------------------------------------------

async def build_user_profile(user: User, db: AsyncSession) -> UserProfile:
    profile = UserProfile()

    # --- Likes ---
    profile.liked_ids = set(user.likes or [])

    # --- Saved & favorites ---
    profile.saved_ids = set(user.saved_posts or [])
    profile.favorite_ids = set(user.favorite_posts or [])

    # --- Reading progress ---
    rp_result = await db.execute(
        select(ReadingProgress).where(ReadingProgress.user_id == user.id)
    )
    for rp in rp_result.scalars().all():
        fid = str(rp.feed_item_id)
        profile.read_ids.add(fid)
        if rp.completed:
            profile.completed_ids.add(fid)
        elif rp.scroll_position and rp.scroll_position < 0.25:
            profile.abandoned_ids.add(fid)

    # --- Highlights (strong engagement signal) ---
    hl_result = await db.execute(
        select(Highlight.feed_item_id).where(Highlight.user_id == user.id).distinct()
    )
    profile.highlighted_item_ids = {str(row[0]) for row in hl_result.all()}

    # --- Gather all interacted item IDs to fetch their metadata ---
    all_ids_str = (
        profile.liked_ids
        | profile.read_ids
        | profile.saved_ids
        | profile.favorite_ids
        | profile.highlighted_item_ids
    )
    if not all_ids_str:
        return profile

    all_uuids = []
    for sid in all_ids_str:
        try:
            all_uuids.append(UUID(sid))
        except ValueError:
            continue

    items_result = await db.execute(
        select(FeedItem).where(FeedItem.id.in_(all_uuids))
    )
    items = items_result.scalars().all()

    for item in items:
        iid = str(item.id)

        # Weight multipliers based on engagement strength
        w = 1.0
        if iid in profile.liked_ids:
            w += 2.0
        if iid in profile.favorite_ids:
            w += 3.0
        if iid in profile.saved_ids:
            w += 1.5
        if iid in profile.highlighted_item_ids:
            w += 2.5
        if iid in profile.completed_ids:
            w += 2.0
        if iid in profile.abandoned_ids:
            w -= 1.5  # penalise patterns from abandoned reads

        for g in (item.genres or []):
            profile.genre_weights[g] += w
        for t in (item.tags or []):
            profile.tag_weights[t] += w
        for wt in (item.writing_types or []):
            profile.type_weights[wt] += w

    return profile


# ---------------------------------------------------------------------------
# 2. Score candidate items
# ---------------------------------------------------------------------------

def _freshness_score(created_at: datetime, half_life_days: float = 7.0) -> float:
    """Exponential decay — items lose half their freshness bonus every `half_life_days`."""
    age_days = (datetime.now(UTC) - created_at.replace(tzinfo=UTC)).total_seconds() / 86400
    return math.exp(-0.693 * age_days / half_life_days)


def _popularity_score(likes: int, comments: int) -> float:
    """Log-scaled popularity so a few viral posts don't dominate."""
    return math.log1p(likes + comments * 2)


def score_item(item: FeedItem, profile: UserProfile) -> float:
    """Compute a recommendation score for a single feed item."""
    iid = str(item.id)

    # Skip items the user already interacted with heavily
    if iid in profile.completed_ids or iid in profile.liked_ids:
        return -1.0  # filter out later

    # --- Preference overlap ---
    genre_score = sum(profile.genre_weights.get(g, 0) for g in (item.genres or []))
    tag_score = sum(profile.tag_weights.get(t, 0) for t in (item.tags or []))
    type_score = sum(profile.type_weights.get(wt, 0) for wt in (item.writing_types or []))
    preference = genre_score * 1.5 + tag_score * 1.0 + type_score * 1.2

    # --- Freshness & popularity ---
    freshness = _freshness_score(item.created_at) * 5.0
    popularity = _popularity_score(item.likes_count or 0, item.comments_count or 0) * 2.0

    # --- Small penalty if item was already started but abandoned ---
    penalty = -3.0 if iid in profile.abandoned_ids else 0.0

    return preference + freshness + popularity + penalty


async def get_scored_candidates(
    user: User,
    profile: UserProfile,
    db: AsyncSession,
    limit: int = 50,
) -> list[tuple[FeedItem, float]]:
    """Fetch published feed items, score them, return top `limit`."""
    result = await db.execute(
        select(FeedItem)
        .where(FeedItem.is_draft == False, FeedItem.author_id != user.id)  # noqa: E712
        .order_by(FeedItem.created_at.desc())
        .limit(500)  # candidate pool
    )
    candidates = result.scalars().all()

    scored = []
    for item in candidates:
        s = score_item(item, profile)
        if s > 0:
            scored.append((item, s))

    scored.sort(key=lambda x: x[1], reverse=True)
    return scored[:limit]


# ---------------------------------------------------------------------------
# 3. (Optional) LLM re-ranker agent
# ---------------------------------------------------------------------------

class RankedRecommendation(BaseModel):
    feed_item_id: str
    reason: str


class RerankedList(BaseModel):
    recommendations: list[RankedRecommendation]


@dataclass
class RerankerDeps:
    top_genres: list[str] = field(default_factory=list)
    top_tags: list[str] = field(default_factory=list)


reranker_agent = Agent(
    model=model,
    deps_type=RerankerDeps,
    result_type=RerankedList,
    system_prompt=(
        "You are a reading recommendation engine for InkSpaceX. "
        "You receive a user's top preferred genres and tags, and a list of "
        "candidate writings (id, title, genres, tags, score). "
        "Re-order them to maximise reading satisfaction — balance familiarity "
        "(matching preferences) with discovery (introducing adjacent genres). "
        "Return the re-ordered list with a short, friendly one-sentence reason "
        "for each pick. Keep all item IDs; do not drop any."
    ),
)


async def rerank_with_llm(
    scored: list[tuple[FeedItem, float]],
    profile: UserProfile,
) -> list[ScoredItem]:
    """Pass top candidates through the LLM for personalised re-ranking."""
    # Build the candidate text block for the prompt
    candidate_lines = []
    for item, sc in scored:
        candidate_lines.append(
            f"- id={item.id} | title=\"{item.title}\" | "
            f"genres={item.genres or []} | tags={item.tags or []} | score={sc:.1f}"
        )
    candidates_text = "\n".join(candidate_lines)

    top_genres = [g for g, _ in profile.genre_weights.most_common(5)]
    top_tags = [t for t, _ in profile.tag_weights.most_common(5)]

    deps = RerankerDeps(top_genres=top_genres, top_tags=top_tags)

    prompt = (
        f"User's top genres: {top_genres}\n"
        f"User's top tags: {top_tags}\n\n"
        f"Candidate writings:\n{candidates_text}\n\n"
        "Re-rank these to maximise the user's reading satisfaction."
    )

    result = await reranker_agent.run(prompt, deps=deps)
    reranked = result.output

    # Map back to ScoredItem with reasons
    item_map = {str(item.id): (item, sc) for item, sc in scored}
    output: list[ScoredItem] = []
    for rec in reranked.recommendations:
        if rec.feed_item_id in item_map:
            item, sc = item_map[rec.feed_item_id]
            output.append(ScoredItem(
                feed_item_id=rec.feed_item_id,
                title=item.title,
                author=item.author,
                genres=item.genres or [],
                tags=item.tags or [],
                score=sc,
                reason=rec.reason,
            ))
    return output


# ---------------------------------------------------------------------------
# 4. Public API — called by the router
# ---------------------------------------------------------------------------

async def recommend_for_user(
    user: User,
    db: AsyncSession,
    limit: int = 20,
    use_llm_rerank: bool = False,
) -> RecommendationResult:
    profile = await build_user_profile(user, db)

    scored = await get_scored_candidates(user, profile, db, limit=limit)

    if use_llm_rerank and scored:
        items = await rerank_with_llm(scored, profile)
    else:
        items = [
            ScoredItem(
                feed_item_id=str(item.id),
                title=item.title,
                author=item.author,
                genres=item.genres or [],
                tags=item.tags or [],
                score=sc,
            )
            for item, sc in scored
        ]

    summary = ProfileSummary(
        top_genres=[g for g, _ in profile.genre_weights.most_common(5)],
        top_tags=[t for t, _ in profile.tag_weights.most_common(5)],
        top_types=[t for t, _ in profile.type_weights.most_common(5)],
        total_reads=len(profile.read_ids),
        total_likes=len(profile.liked_ids),
    )

    return RecommendationResult(items=items[:limit], profile_summary=summary)
