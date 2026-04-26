from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.feed_item import FeedItem
from app.models.reading_progress import ReadingProgress
from app.models.user import User
from app.schemas.reading import (
    ContinueReadingItem,
    ReadingProgressResponse,
    ReadingProgressUpdate,
)

router = APIRouter(prefix="/api/reading-progress", tags=["reading"])


@router.get("/continue-reading", response_model=list[ContinueReadingItem])
async def continue_reading(
    limit: int = Query(8, ge=1, le=24),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Items the user has started but not finished, newest activity first.

    Joined with `feed_items` so the rail can render a cover + title in
    one round trip. Completed items are excluded — they belong on a
    "finished" rail, not the resume one.
    """

    query = (
        select(
            FeedItem.id.label("feed_item_id"),
            FeedItem.title,
            FeedItem.author,
            FeedItem.image_url,
            FeedItem.image_meta,
            ReadingProgress.scroll_position,
            ReadingProgress.last_read_at,
            ReadingProgress.last_section_id,
            ReadingProgress.last_anchor,
            ReadingProgress.completed,
        )
        .join(FeedItem, FeedItem.id == ReadingProgress.feed_item_id)
        .where(
            ReadingProgress.user_id == user.id,
            ReadingProgress.completed.is_(False),
            ReadingProgress.last_read_at.is_not(None),
        )
        .order_by(ReadingProgress.last_read_at.desc())
        .limit(limit)
    )
    result = await db.execute(query)
    return [
        ContinueReadingItem(
            feed_item_id=row.feed_item_id,
            title=row.title,
            author=row.author,
            image_url=row.image_url,
            image_meta=row.image_meta,
            scroll_position=row.scroll_position,
            last_read_at=row.last_read_at,
            last_section_id=row.last_section_id,
            last_anchor=row.last_anchor,
            completed=row.completed,
        )
        for row in result.all()
    ]


@router.get("/{feed_item_id}", response_model=ReadingProgressResponse | None)
async def get_reading_progress(
    feed_item_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(ReadingProgress).where(
            ReadingProgress.user_id == user.id,
            ReadingProgress.feed_item_id == feed_item_id,
        )
    )
    return result.scalar_one_or_none()


@router.put("/{feed_item_id}", response_model=ReadingProgressResponse)
async def upsert_reading_progress(
    feed_item_id: UUID,
    data: ReadingProgressUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(ReadingProgress).where(
            ReadingProgress.user_id == user.id,
            ReadingProgress.feed_item_id == feed_item_id,
        )
    )
    progress = result.scalar_one_or_none()

    if progress is None:
        progress = ReadingProgress(
            user_id=user.id,
            feed_item_id=feed_item_id,
        )
        db.add(progress)

    if data.scroll_position is not None:
        progress.scroll_position = data.scroll_position
    if data.completed is not None:
        progress.completed = data.completed
    if data.last_section_id is not None:
        progress.last_section_id = data.last_section_id
    if data.last_anchor is not None:
        progress.last_anchor = data.last_anchor
    progress.last_read_at = datetime.now(UTC)

    await db.commit()
    await db.refresh(progress)

    # Reading progress shifts the user's profile (completed boosts the
    # genre weight; abandoned penalises it). Drop the cache so the next
    # /api/ai/recommendations call rebuilds with fresh signals.
    from app.ai.recommendation import invalidate_user_profile_cache
    invalidate_user_profile_cache(user.id)

    return progress
