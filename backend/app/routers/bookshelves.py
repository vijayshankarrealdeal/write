from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.bookshelf import Bookshelf
from app.models.user import User
from app.schemas.bookshelf import BookshelfCreate, BookshelfResponse, BookshelfUpdate

router = APIRouter(prefix="/api/bookshelves", tags=["bookshelves"])


@router.get("/", response_model=list[BookshelfResponse])
async def list_bookshelves(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Bookshelf)
        .where(Bookshelf.user_id == user.id)
        .order_by(Bookshelf.updated_at.desc())
    )
    return result.scalars().all()


@router.post("/", response_model=BookshelfResponse, status_code=201)
async def create_bookshelf(
    data: BookshelfCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    bookshelf = Bookshelf(user_id=user.id, **data.model_dump())
    db.add(bookshelf)
    await db.commit()
    await db.refresh(bookshelf)
    return bookshelf


@router.get("/{bookshelf_id}", response_model=BookshelfResponse)
async def get_bookshelf(
    bookshelf_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Bookshelf).where(Bookshelf.id == bookshelf_id, Bookshelf.user_id == user.id)
    )
    bookshelf = result.scalar_one_or_none()
    if not bookshelf:
        raise HTTPException(status_code=404, detail="Bookshelf not found")
    return bookshelf


@router.put("/{bookshelf_id}", response_model=BookshelfResponse)
async def update_bookshelf(
    bookshelf_id: UUID,
    data: BookshelfUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Bookshelf).where(Bookshelf.id == bookshelf_id, Bookshelf.user_id == user.id)
    )
    bookshelf = result.scalar_one_or_none()
    if not bookshelf:
        raise HTTPException(status_code=404, detail="Bookshelf not found")
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(bookshelf, field, value)
    await db.commit()
    await db.refresh(bookshelf)
    return bookshelf


@router.delete("/{bookshelf_id}", status_code=204)
async def delete_bookshelf(
    bookshelf_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Bookshelf).where(Bookshelf.id == bookshelf_id, Bookshelf.user_id == user.id)
    )
    bookshelf = result.scalar_one_or_none()
    if not bookshelf:
        raise HTTPException(status_code=404, detail="Bookshelf not found")
    await db.delete(bookshelf)
    await db.commit()
