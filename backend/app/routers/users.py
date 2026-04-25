from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.user import User
from app.schemas.user import ListUpdateRequest, UserResponse, UserUpdate

router = APIRouter(prefix="/api/users", tags=["users"])


@router.get("/me", response_model=UserResponse)
async def get_profile(user: User = Depends(get_current_user)):
    return user


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
    return {"ok": True, field: current}
