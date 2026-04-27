from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.feed_item import FeedItem
from app.models.user import User
from app.schemas.user import ListUpdateRequest, UserResponse, UserUpdate

router = APIRouter(prefix="/api/users", tags=["users"])


class PublicUser(BaseModel):
    """Slim user record for search results / public profile listings.

    Excludes private fields (email, lists, onboarding state) that are
    only relevant to the user themselves.
    """

    id: UUID
    name: str | None
    photo_url: str | None
    photo_meta: dict | None = None
    posts_count: int = 0

    model_config = {"from_attributes": True}


@router.get("/me", response_model=UserResponse)
async def get_profile(user: User = Depends(get_current_user)):
    return user


@router.get("/search", response_model=list[PublicUser])
async def search_users(
    q: str = Query(..., min_length=1, max_length=200),
    limit: int = Query(20, ge=1, le=50),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Fuzzy author search by display name. Joins published-post counts
    so the client can surface "X stories" next to each result and rank
    productive authors above empty profiles."""
    term = q.strip()
    if not term:
        return []
    pattern = f"%{term}%"
    posts_count = (
        select(func.count(FeedItem.id))
        .where(FeedItem.author_id == User.id)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .correlate(User)
        .scalar_subquery()
    )
    stmt = (
        select(User, posts_count.label("posts_count"))
        .where(User.name.is_not(None))
        .where(User.name.ilike(pattern))
        .order_by(posts_count.desc(), User.name.asc())
        .limit(limit)
    )
    rows = (await db.execute(stmt)).all()
    return [
        PublicUser(
            id=u.id,
            name=u.name,
            photo_url=u.photo_url,
            photo_meta=u.photo_meta,
            posts_count=int(c or 0),
        )
        for u, c in rows
    ]


@router.get("/{user_id}", response_model=PublicUser)
async def get_public_user(
    user_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Public profile view — the slim, non-sensitive subset of the user
    record, used by the in-app author profile page."""
    posts_count = (
        select(func.count(FeedItem.id))
        .where(FeedItem.author_id == user_id)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .scalar_subquery()
    )
    stmt = select(User, posts_count.label("posts_count")).where(User.id == user_id)
    row = (await db.execute(stmt)).first()
    if not row:
        raise HTTPException(status_code=404, detail="User not found")
    u, c = row
    return PublicUser(
        id=u.id,
        name=u.name,
        photo_url=u.photo_url,
        photo_meta=u.photo_meta,
        posts_count=int(c or 0),
    )


@router.put("/me", response_model=UserResponse)
async def update_profile(
    data: UserUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(user, field, value)
    await db.commit()
    await db.refresh(user)
    return user


@router.post("/me/likes")
async def update_likes(
    req: ListUpdateRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await _update_list(user, "likes", req, db)


@router.post("/me/reading-list")
async def update_reading_list(
    req: ListUpdateRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await _update_list(user, "reading_list", req, db)


@router.post("/me/saved-posts")
async def update_saved_posts(
    req: ListUpdateRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await _update_list(user, "saved_posts", req, db)


@router.post("/me/favorite-posts")
async def update_favorite_posts(
    req: ListUpdateRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await _update_list(user, "favorite_posts", req, db)


@router.post("/me/section-bookmarks")
async def update_section_bookmarks(
    req: ListUpdateRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await _update_list(user, "section_bookmarks", req, db)


async def _update_list(user: User, field: str, req: ListUpdateRequest, db: AsyncSession):
    current: list[str] = getattr(user, field) or []
    if req.action == "add":
        if req.item_id not in current:
            current = [*current, req.item_id]
    elif req.action == "remove":
        current = [item for item in current if item != req.item_id]
    else:
        raise HTTPException(status_code=400, detail="action must be 'add' or 'remove'")

    setattr(user, field, current)
    await db.commit()
    # Any change to a recommendation-relevant list (likes, saved_posts,
    # favorite_posts, reading_list) invalidates the cached profile.
    if field in {"likes", "saved_posts", "favorite_posts", "reading_list"}:
        from app.ai.recommendation import invalidate_user_profile_cache
        invalidate_user_profile_cache(user.id)
    return {"ok": True, field: current}
