from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.reading_progress import ReadingProgress
from app.models.user import User
from app.schemas.reading import ReadingProgressResponse, ReadingProgressUpdate

router = APIRouter(prefix="/api/reading-progress", tags=["reading"])


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
    progress.last_read_at = datetime.now(UTC)

    await db.commit()
    await db.refresh(progress)
    return progress
