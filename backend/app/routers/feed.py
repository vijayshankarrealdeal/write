from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import array as pg_array
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.types import String

from app.ai.embeddings import schedule_embedding
from app.auth.deps import get_current_user
from app.database import get_db
from app.models.feed_item import FeedItem
from app.models.user import User
from app.notifications import create_notification
from app.schemas.feed import (
    FacetEntry,
    FacetResponse,
    FeedItemCreate,
    FeedItemResponse,
    FeedItemUpdate,
)

router = APIRouter(prefix="/api/feed", tags=["feed"])


def _apply_sort(query, sort: str):
    """Apply the sort clause used by both the main feed and the by-tag/by-genre
    endpoints. Centralised so the cursor logic below stays in lockstep."""
    if sort == "trending" or sort == "top":
        return query.order_by(FeedItem.likes_count.desc(), FeedItem.created_at.desc())
    return query.order_by(FeedItem.created_at.desc())


def _apply_cursor(query, sort: str, cursor_item: FeedItem):
    """Cursor-based pagination predicate matching `_apply_sort`."""
    if sort == "trending" or sort == "top":
        return query.where(
            (FeedItem.likes_count < cursor_item.likes_count)
            | (
                (FeedItem.likes_count == cursor_item.likes_count)
                & (FeedItem.created_at < cursor_item.created_at)
            )
        )
    return query.where(FeedItem.created_at < cursor_item.created_at)


async def _resolve_cursor(cursor: str | None, db: AsyncSession) -> FeedItem | None:
    if not cursor:
        return None
    try:
        cursor_uuid = UUID(cursor)
    except ValueError:
        return None
    result = await db.execute(select(FeedItem).where(FeedItem.id == cursor_uuid))
    return result.scalar_one_or_none()


@router.get("/", response_model=list[FeedItemResponse])
async def list_feed(
    sort: str = Query("recent", pattern="^(recent|trending|top)$"),
    genre: str | None = None,
    genres: list[str] | None = Query(None),
    tags: list[str] | None = Query(None),
    writing_types: list[str] | None = Query(None),
    cursor: str | None = None,
    limit: int = Query(20, le=50),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    query = select(FeedItem).where(FeedItem.is_draft == False)  # noqa: E712

    # Single-value `genre` is kept as a back-compat alias for the
    # multi-value `genres` filter the new chip row sends. Both apply
    # an array-overlap (`&&`) check so the GIN index handles them.
    if genre:
        query = query.where(FeedItem.genres.op("&&")(pg_array([genre], type_=String)))
    if genres:
        query = query.where(FeedItem.genres.op("&&")(pg_array(genres, type_=String)))
    if tags:
        query = query.where(FeedItem.tags.op("&&")(pg_array(tags, type_=String)))
    if writing_types:
        query = query.where(FeedItem.writing_types.op("&&")(pg_array(writing_types, type_=String)))

    query = _apply_sort(query, sort)

    cursor_item = await _resolve_cursor(cursor, db)
    if cursor_item is not None:
        query = _apply_cursor(query, sort, cursor_item)

    query = query.limit(limit)
    result = await db.execute(query)
    return result.scalars().all()


# ===== Drill-down: by-tag / by-genre / by-type ===============================

@router.get("/by-tag/{tag}", response_model=list[FeedItemResponse])
async def list_feed_by_tag(
    tag: str,
    sort: str = Query("recent", pattern="^(recent|trending|top)$"),
    cursor: str | None = None,
    limit: int = Query(20, le=50),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """All published items carrying `tag`. Same sort/cursor contract as `/`."""
    query = (
        select(FeedItem)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .where(FeedItem.tags.op("&&")(pg_array([tag], type_=String)))
    )
    query = _apply_sort(query, sort)
    cursor_item = await _resolve_cursor(cursor, db)
    if cursor_item is not None:
        query = _apply_cursor(query, sort, cursor_item)
    query = query.limit(limit)
    result = await db.execute(query)
    return result.scalars().all()


@router.get("/by-genre/{genre}", response_model=list[FeedItemResponse])
async def list_feed_by_genre(
    genre: str,
    sort: str = Query("recent", pattern="^(recent|trending|top)$"),
    cursor: str | None = None,
    limit: int = Query(20, le=50),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """All published items in `genre`. Same sort/cursor contract as `/`."""
    query = (
        select(FeedItem)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .where(FeedItem.genres.op("&&")(pg_array([genre], type_=String)))
    )
    query = _apply_sort(query, sort)
    cursor_item = await _resolve_cursor(cursor, db)
    if cursor_item is not None:
        query = _apply_cursor(query, sort, cursor_item)
    query = query.limit(limit)
    result = await db.execute(query)
    return result.scalars().all()


# ===== Facets (Explore tab + filter chip suggestions) ========================

# How many of each facet bucket we surface. The Explore tab can render
# more chips than fit on a single screen, but we don't want to ship the
# entire long-tail to every client.
_FACET_LIMIT = 32

# Facet aggregation is expensive enough that we hit `feed_facets` (a
# nightly-rebuilt cache table) when present and only fall back to the
# live `array_agg + unnest` query as a last resort. Both code paths
# return the same shape so the client doesn't care which fired.

async def _facet_counts(db: AsyncSession, column) -> list[FacetEntry]:
    # Live query: unnest the array column, group + count.
    val = func.unnest(column).label("value")
    stmt = (
        select(val, func.count().label("count"))
        .where(FeedItem.is_draft == False)  # noqa: E712
        .group_by(val)
        .order_by(func.count().desc())
        .limit(_FACET_LIMIT)
    )
    rows = (await db.execute(stmt)).all()
    return [FacetEntry(value=str(r.value), count=int(r.count)) for r in rows if r.value]


@router.get("/facets", response_model=FacetResponse)
async def list_feed_facets(
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Top genres + tags + writing_types with item counts.

    Powers the Explore tab and the persistent filter chip row on the
    main feed. Live-aggregated for now; once the catalogue grows past
    a few thousand published items, hydrate from a nightly-built
    `feed_facets` cache table instead.
    """
    genres = await _facet_counts(db, FeedItem.genres)
    tags = await _facet_counts(db, FeedItem.tags)
    types = await _facet_counts(db, FeedItem.writing_types)
    return FacetResponse(genres=genres, tags=tags, writing_types=types)


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
    if not item.is_draft:
        schedule_embedding(item.id)
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
    was_draft = item.is_draft
    text_changed = False
    payload = data.model_dump(exclude_unset=True)
    for field, value in payload.items():
        if field in {"title", "description", "sections"} and getattr(item, field) != value:
            text_changed = True
        setattr(item, field, value)
    await db.commit()
    await db.refresh(item)
    # Re-embed when the item transitions to published, or when its
    # text-bearing fields change while already published. The publish
    # path must not block on Azure — fire-and-forget.
    if not item.is_draft and (was_draft or text_changed or item.embedding is None):
        schedule_embedding(item.id)
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
        await db.flush()
        # Notify the post's author when someone else likes it.
        await create_notification(
            db,
            recipient_id=item.author_id,
            kind="like",
            actor=user,
            feed_item=item,
            data={"likes_count": item.likes_count},
        )
        await db.commit()
        # Recommendation profile cache is keyed on the user's signal
        # set; a like changes that set, so drop the stale cache entry.
        from app.ai.recommendation import invalidate_user_profile_cache
        invalidate_user_profile_cache(user.id)

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
        from app.ai.recommendation import invalidate_user_profile_cache
        invalidate_user_profile_cache(user.id)

    return {"likes_count": item.likes_count}
