from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.highlight import Highlight
from app.models.user import User
from app.schemas.highlight import HighlightCreate, HighlightResponse

router = APIRouter(prefix="/api/highlights", tags=["highlights"])


@router.get("/", response_model=list[HighlightResponse])
async def list_highlights(
    feed_item_id: UUID | None = None,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    query = select(Highlight).where(Highlight.user_id == user.id)
    if feed_item_id:
        query = query.where(Highlight.feed_item_id == feed_item_id)
    query = query.order_by(Highlight.created_at.desc())
    result = await db.execute(query)
    return result.scalars().all()


@router.post("/", response_model=HighlightResponse, status_code=201)
async def create_highlight(
    data: HighlightCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    highlight = Highlight(user_id=user.id, **data.model_dump())
    db.add(highlight)
    await db.commit()
    await db.refresh(highlight)
    return highlight


@router.delete("/{highlight_id}", status_code=204)
async def delete_highlight(
    highlight_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Highlight).where(Highlight.id == highlight_id, Highlight.user_id == user.id)
    )
    highlight = result.scalar_one_or_none()
    if not highlight:
        raise HTTPException(status_code=404, detail="Highlight not found")
    await db.delete(highlight)
    await db.commit()
