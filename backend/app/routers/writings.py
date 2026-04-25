from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.section import Section
from app.models.user import User
from app.models.writing import Writing
from app.schemas.writing import (
    SectionCreate,
    SectionResponse,
    SectionUpdate,
    WritingCreate,
    WritingResponse,
    WritingUpdate,
)

router = APIRouter(prefix="/api/writings", tags=["writings"])


# --- Writings ---


@router.get("/", response_model=list[WritingResponse])
async def list_writings(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Writing).where(Writing.user_id == user.id).order_by(Writing.updated_at.desc())
    )
    return result.scalars().all()


@router.post("/", response_model=WritingResponse, status_code=201)
async def create_writing(
    data: WritingCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    writing = Writing(
        user_id=user.id,
        author=user.name,
        **data.model_dump(),
    )
    db.add(writing)
    await db.commit()
    await db.refresh(writing)
    return writing


@router.get("/{writing_id}", response_model=WritingResponse)
async def get_writing(
    writing_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    writing = await _get_user_writing(writing_id, user.id, db)
    return writing


@router.put("/{writing_id}", response_model=WritingResponse)
async def update_writing(
    writing_id: UUID,
    data: WritingUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    writing = await _get_user_writing(writing_id, user.id, db)
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(writing, field, value)
    await db.commit()
    await db.refresh(writing)
    return writing


@router.delete("/{writing_id}", status_code=204)
async def delete_writing(
    writing_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    writing = await _get_user_writing(writing_id, user.id, db)
    await db.delete(writing)
    await db.commit()


# --- Sections ---


@router.get("/{writing_id}/sections", response_model=list[SectionResponse])
async def list_sections(
    writing_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await _get_user_writing(writing_id, user.id, db)
    result = await db.execute(
        select(Section).where(Section.writing_id == writing_id)
    )
    return result.scalars().all()


@router.post("/{writing_id}/sections", response_model=SectionResponse, status_code=201)
async def create_section(
    writing_id: UUID,
    data: SectionCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    writing = await _get_user_writing(writing_id, user.id, db)
    section = Section(writing_id=writing_id, **data.model_dump())
    db.add(section)
    # Add section ID to the writing's section_ids list
    writing.section_ids = [*(writing.section_ids or []), str(section.id)]
    await db.commit()
    await db.refresh(section)
    return section


@router.put("/{writing_id}/sections/{section_id}", response_model=SectionResponse)
async def update_section(
    writing_id: UUID,
    section_id: UUID,
    data: SectionUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await _get_user_writing(writing_id, user.id, db)
    result = await db.execute(
        select(Section).where(Section.id == section_id, Section.writing_id == writing_id)
    )
    section = result.scalar_one_or_none()
    if not section:
        raise HTTPException(status_code=404, detail="Section not found")
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(section, field, value)
    await db.commit()
    await db.refresh(section)
    return section


@router.delete("/{writing_id}/sections/{section_id}", status_code=204)
async def delete_section(
    writing_id: UUID,
    section_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    writing = await _get_user_writing(writing_id, user.id, db)
    result = await db.execute(
        select(Section).where(Section.id == section_id, Section.writing_id == writing_id)
    )
    section = result.scalar_one_or_none()
    if not section:
        raise HTTPException(status_code=404, detail="Section not found")
    writing.section_ids = [sid for sid in (writing.section_ids or []) if sid != str(section_id)]
    await db.delete(section)
    await db.commit()


async def _get_user_writing(writing_id: UUID, user_id, db: AsyncSession) -> Writing:
    result = await db.execute(
        select(Writing).where(Writing.id == writing_id, Writing.user_id == user_id)
    )
    writing = result.scalar_one_or_none()
    if not writing:
        raise HTTPException(status_code=404, detail="Writing not found")
    return writing
