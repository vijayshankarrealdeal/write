"""Per-section emoji reactions.

Section-level granularity (one reaction-set per chapter). Paragraph-
level is a Phase 2 problem.

Endpoints (all under ``/api/feed/{item_id}/sections/{section_id}/reactions``):

* ``POST   {emoji}``   — add the caller's reaction. Idempotent: if it
  already exists the row stays as-is. Returns the updated aggregate.
* ``DELETE {emoji}``   — remove the caller's reaction. Idempotent.
* ``GET``              — full per-emoji aggregate plus a small
  ``recent_users`` slice for each one, used by the bottom-sheet
  detail view ("who reacted with 🔥").

The lightweight summary (``[{emoji, count, you}]``) is also folded
into ``feed_sections.list_section_stubs`` so the chapter list paints
counts in one round-trip — see that file.

Visibility: a reader can react to any section they can already read.
We reuse the public_feed_clause from feed.py rather than duplicating
the visibility rule here; auth via the standard ``get_current_user``.
"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import delete, func, or_, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.feed_visibility import public_feed_clause
from app.models.feed_item import FeedItem
from app.models.section import Section
from app.models.section_reaction import SectionReaction
from app.models.user import User
from app.models.writing import Writing


router = APIRouter(
    prefix="/api/feed/{item_id}/sections/{section_id}/reactions",
    tags=["reactions"],
)


# Server-side allowlist mirrors the client's fixed picker. Keeps a
# typo'd or hostile client from filling the table with garbage; new
# emojis can be added here without a migration.
ALLOWED_EMOJIS: set[str] = {
    "❤️",
    "🔥",
    "😂",
    "😢",
    "😮",
    "👏",
    "🤔",
    "⭐",
}


class ReactionAggregate(BaseModel):
    """One row per emoji that's been used on this section."""

    emoji: str
    count: int
    you: bool = Field(
        default=False,
        description="True if the caller has this emoji on this section.",
    )


class _ReactorBrief(BaseModel):
    name: str | None
    photo_url: str | None


class ReactionDetail(ReactionAggregate):
    """Aggregate plus a small slice of who recently reacted, for the
    bottom-sheet detail view."""

    recent_users: list[_ReactorBrief] = []


class ReactionRequest(BaseModel):
    emoji: str


async def _section_visible(
    db: AsyncSession, item_id: UUID, section_id: UUID, user: User
) -> Section:
    """Resolve a section the caller can read, or 404. The check
    composes:

    1. Section belongs to the writing referenced by this feed item.
    2. The feed item is visible to the caller (public-feed gate or
       owned by the caller).

    A 404 (not 403) hides the existence of unauthorized rows the same
    way the rest of the feed router does.
    """
    row = (
        await db.execute(
            select(Section, FeedItem)
            .join(Writing, Writing.id == Section.writing_id)
            .join(FeedItem, FeedItem.writing_id == Writing.id)
            .where(
                Section.id == section_id,
                FeedItem.id == item_id,
                or_(
                    FeedItem.author_id == user.id,
                    public_feed_clause(user.id),
                ),
            )
        )
    ).first()
    if row is None:
        raise HTTPException(status_code=404, detail="section not found")
    return row[0]


async def _aggregate(
    db: AsyncSession, section_id: UUID, user_id: UUID
) -> list[ReactionAggregate]:
    """Per-emoji count + whether the caller has voted that emoji."""
    counts = (
        await db.execute(
            select(
                SectionReaction.emoji,
                func.count(SectionReaction.id).label("count"),
                func.bool_or(SectionReaction.user_id == user_id).label("you"),
            )
            .where(SectionReaction.section_id == section_id)
            .group_by(SectionReaction.emoji)
            .order_by(func.count(SectionReaction.id).desc(), SectionReaction.emoji)
        )
    ).all()
    return [
        ReactionAggregate(emoji=row.emoji, count=row.count, you=bool(row.you))
        for row in counts
    ]


@router.get("", response_model=list[ReactionDetail])
async def list_reactions(
    item_id: UUID,
    section_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Per-emoji aggregate plus up to 5 recent reactors per emoji.

    Used by the bottom-sheet that opens when the user taps an emoji
    pill ("show me everyone who reacted 🔥").
    """
    await _section_visible(db, item_id, section_id, user)
    aggregates = await _aggregate(db, section_id, user.id)

    # One additional query per emoji is fine — section reactions live
    # in the low double digits per chapter at most. If this ever scales
    # to thousands per section we'll switch to a single windowed query.
    details: list[ReactionDetail] = []
    for agg in aggregates:
        recent = (
            await db.execute(
                select(User.name, User.photo_url)
                .join(SectionReaction, SectionReaction.user_id == User.id)
                .where(
                    SectionReaction.section_id == section_id,
                    SectionReaction.emoji == agg.emoji,
                )
                .order_by(SectionReaction.created_at.desc())
                .limit(5)
            )
        ).all()
        details.append(
            ReactionDetail(
                emoji=agg.emoji,
                count=agg.count,
                you=agg.you,
                recent_users=[
                    _ReactorBrief(name=r.name, photo_url=r.photo_url) for r in recent
                ],
            )
        )
    return details


@router.post("", response_model=list[ReactionAggregate])
async def add_reaction(
    item_id: UUID,
    section_id: UUID,
    body: ReactionRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Add the caller's reaction. Idempotent (PG ON CONFLICT)."""
    if body.emoji not in ALLOWED_EMOJIS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"emoji not allowed: {body.emoji}",
        )
    await _section_visible(db, item_id, section_id, user)
    await db.execute(
        pg_insert(SectionReaction)
        .values(
            section_id=section_id,
            user_id=user.id,
            emoji=body.emoji,
        )
        .on_conflict_do_nothing(
            index_elements=["section_id", "user_id", "emoji"],
        )
    )
    await db.commit()
    return await _aggregate(db, section_id, user.id)


@router.delete("/{emoji}", response_model=list[ReactionAggregate])
async def remove_reaction(
    item_id: UUID,
    section_id: UUID,
    emoji: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Remove the caller's reaction. Idempotent (a no-op DELETE if
    the row doesn't exist)."""
    await _section_visible(db, item_id, section_id, user)
    await db.execute(
        delete(SectionReaction).where(
            SectionReaction.section_id == section_id,
            SectionReaction.user_id == user.id,
            SectionReaction.emoji == emoji,
        )
    )
    await db.commit()
    return await _aggregate(db, section_id, user.id)
