from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.feed_item import FeedItem
from app.models.user import User
from app.schemas.feed import FeedItemCreate, FeedItemResponse, FeedItemUpdate

router = APIRouter(prefix="/api/feed", tags=["feed"])


@router.get("/", response_model=list[FeedItemResponse])
async def list_feed(
    sort: str = Query("recent", pattern="^(recent|trending)$"),
    genre: str | None = None,
    cursor: str | None = None,
    limit: int = Query(20, le=50),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    query = select(FeedItem).where(FeedItem.is_draft == False)  # noqa: E712

    if genre:
        query = query.where(FeedItem.genres.contains([genre]))

    if sort == "trending":
        query = query.order_by(FeedItem.likes_count.desc(), FeedItem.created_at.desc())
    else:
        query = query.order_by(FeedItem.created_at.desc())

    if cursor:
        try:
            cursor_uuid = UUID(cursor)
            # Get the cursor item to paginate after it
            cursor_result = await db.execute(select(FeedItem).where(FeedItem.id == cursor_uuid))
            cursor_item = cursor_result.scalar_one_or_none()
            if cursor_item:
                if sort == "trending":
                    query = query.where(
                        (FeedItem.likes_count < cursor_item.likes_count)
                        | (
                            (FeedItem.likes_count == cursor_item.likes_count)
                            & (FeedItem.created_at < cursor_item.created_at)
                        )
                    )
                else:
                    query = query.where(FeedItem.created_at < cursor_item.created_at)
        except ValueError:
            pass

    query = query.limit(limit)
    result = await db.execute(query)
    return result.scalars().all()


@router.get("/by-author/{author_id}", response_model=list[FeedItemResponse])
async def list_feed_by_author(
    author_id: UUID,
    include_drafts: bool = False,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    query = select(FeedItem).where(FeedItem.author_id == author_id)
    if not include_drafts or author_id != user.id:
        query = query.where(FeedItem.is_draft == False)  # noqa: E712
    query = query.order_by(FeedItem.created_at.desc())
    result = await db.execute(query)
    return result.scalars().all()


@router.post("/", response_model=FeedItemResponse, status_code=201)
async def create_feed_item(
    data: FeedItemCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    item = FeedItem(
        author=user.name,
        author_id=user.id,
        **data.model_dump(),
    )
    db.add(item)
    await db.commit()
    await db.refresh(item)
    return item


@router.get("/{item_id}", response_model=FeedItemResponse)
async def get_feed_item(
    item_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    result = await db.execute(select(FeedItem).where(FeedItem.id == item_id))
    item = result.scalar_one_or_none()
    if not item:
        raise HTTPException(status_code=404, detail="Feed item not found")
    return item


@router.put("/{item_id}", response_model=FeedItemResponse)
async def update_feed_item(
    item_id: UUID,
    data: FeedItemUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(FeedItem).where(FeedItem.id == item_id, FeedItem.author_id == user.id)
    )
    item = result.scalar_one_or_none()
    if not item:
        raise HTTPException(status_code=404, detail="Feed item not found or not yours")
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(item, field, value)
    await db.commit()
    await db.refresh(item)
    return item


@router.delete("/{item_id}", status_code=204)
async def delete_feed_item(
    item_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(FeedItem).where(FeedItem.id == item_id, FeedItem.author_id == user.id)
    )
    item = result.scalar_one_or_none()
    if not item:
        raise HTTPException(status_code=404, detail="Feed item not found or not yours")
    await db.delete(item)
    await db.commit()


@router.post("/{item_id}/like")
async def like_feed_item(
    item_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(FeedItem).where(FeedItem.id == item_id))
    item = result.scalar_one_or_none()
    if not item:
        raise HTTPException(status_code=404, detail="Feed item not found")

    item_id_str = str(item_id)
    if item_id_str not in (user.likes or []):
        user.likes = [*(user.likes or []), item_id_str]
        item.likes_count = (item.likes_count or 0) + 1
        await db.commit()

    return {"likes_count": item.likes_count}


@router.delete("/{item_id}/like")
async def unlike_feed_item(
    item_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(FeedItem).where(FeedItem.id == item_id))
    item = result.scalar_one_or_none()
    if not item:
        raise HTTPException(status_code=404, detail="Feed item not found")

    item_id_str = str(item_id)
    if item_id_str in (user.likes or []):
        user.likes = [lid for lid in (user.likes or []) if lid != item_id_str]
        item.likes_count = max(0, (item.likes_count or 0) - 1)
        await db.commit()

    return {"likes_count": item.likes_count}
