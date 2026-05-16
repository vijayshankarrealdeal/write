import uuid
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.feed_item import FeedItem
from app.models.reading_progress import ReadingProgress
from app.models.section import Section
from app.models.user import User
from app.models.writing import Writing
from app.realtime import hub
from app.schemas.writing import (
    SectionCreate,
    SectionResponse,
    SectionUpdate,
    WritingCreate,
    WritingResponse,
    WritingUpdate,
)

router = APIRouter(prefix="/api/writings", tags=["writings"])


# Origin tag for echo suppression. The originating client passes a uuid in
# X-Op-Id and we mirror it in every broadcast payload from the same commit.
# The client checks the field and ignores events tagged with one of its own
# in-flight op ids so it doesn't redundantly re-apply its own write.
def _op_id(x_op_id: str | None = Header(default=None, alias="X-Op-Id")) -> str | None:
    return x_op_id


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


# Writing fields that, when changed, should propagate to a published
# FeedItem. Price/visibility/draft state are deliberately excluded —
# they remain explicit publish-time decisions an author makes in the
# publish dialog, not side effects of a typo fix on the draft.
_FEED_SYNCABLE_FIELDS: frozenset[str] = frozenset(
    {
        "title",
        "description",
        "cover_image_path",
        "cover_image_meta",
        "writing_type",
    }
)


@router.put("/{writing_id}", response_model=WritingResponse)
async def update_writing(
    writing_id: UUID,
    data: WritingUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    op_id: str | None = Depends(_op_id),
):
    writing = await _get_user_writing(writing_id, user.id, db)
    changes = data.model_dump(exclude_unset=True)
    for field, value in changes.items():
        setattr(writing, field, value)
    await db.commit()
    await db.refresh(writing)

    # Auto-sync metadata to the published FeedItem so readers see the
    # corrected title/description/cover without forcing the author to
    # re-open the publish flow. Drafts stay frozen — the FeedItem only
    # gets refreshed once explicitly published. Genres/tags are not in
    # the Writing schema so they're carried over from the existing card
    # unchanged; same for price/currency/visibility/author/publisher,
    # which remain author-controlled publish-time decisions.
    #
    # `upsert_feed_item_for_writing` is imported lazily — its module
    # transitively pulls in the embeddings agent (and a heavy
    # pydantic_ai stack) that we don't want to load when none of the
    # syncable fields changed, and that test envs without the AI
    # dependencies can't import at all.
    if changes and any(f in _FEED_SYNCABLE_FIELDS for f in changes):
        feed_item = (
            await db.execute(
                select(FeedItem).where(FeedItem.writing_id == writing.id)
            )
        ).scalar_one_or_none()
        if feed_item is not None and not feed_item.is_draft:
            publisher = await db.get(User, feed_item.author_id)
            if publisher is not None:
                from app.feed_publish import upsert_feed_item_for_writing

                await upsert_feed_item_for_writing(
                    db,
                    writing_id=writing.id,
                    publisher=publisher,
                    title=writing.title,
                    description=writing.description,
                    image_url=writing.cover_image_path,
                    image_meta=writing.cover_image_meta,
                    genres=list(feed_item.genres or []),
                    writing_types=(
                        [writing.writing_type] if writing.writing_type else []
                    ),
                    tags=list(feed_item.tags or []),
                    is_draft=feed_item.is_draft,
                    visibility=feed_item.visibility,
                    price_cents=feed_item.price_cents,
                    currency=feed_item.currency,
                    author_display=feed_item.author,
                )

    await hub.broadcast_writing(
        writing_id,
        {
            "type": "writing.updated",
            "op_id": op_id,
            "writing": WritingResponse.model_validate(writing).model_dump(mode="json"),
        },
    )
    return writing


@router.delete("/{writing_id}", status_code=204)
async def delete_writing(
    writing_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    op_id: str | None = Depends(_op_id),
):
    writing = await _get_user_writing(writing_id, user.id, db)
    await db.delete(writing)
    await db.commit()
    await hub.broadcast_writing(
        writing_id,
        {
            "type": "writing.deleted",
            "op_id": op_id,
            "writing_id": str(writing_id),
        },
    )


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
    op_id: str | None = Depends(_op_id),
):
    writing = await _get_user_writing(writing_id, user.id, db)
    # Assign the UUID up front. SQLAlchemy's `default=uuid.uuid4` only
    # fires at flush time, so reading `section.id` before commit returns
    # None and `str(None)` would push the literal string "None" into
    # Writing.section_ids — leaving the chapter list permanently empty
    # for readers (uuid.UUID("None") raises ValueError downstream).
    section = Section(id=uuid.uuid4(), writing_id=writing_id, **data.model_dump())
    db.add(section)
    writing.section_ids = [*(writing.section_ids or []), str(section.id)]
    await db.commit()
    await db.refresh(section)
    await hub.broadcast_writing(
        writing_id,
        {
            "type": "section.created",
            "op_id": op_id,
            "section": SectionResponse.model_validate(section).model_dump(mode="json"),
            "section_ids": list(writing.section_ids or []),
        },
    )
    return section


@router.put("/{writing_id}/sections/{section_id}", response_model=SectionResponse)
async def update_section(
    writing_id: UUID,
    section_id: UUID,
    data: SectionUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    op_id: str | None = Depends(_op_id),
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
    await hub.broadcast_writing(
        writing_id,
        {
            "type": "section.updated",
            "op_id": op_id,
            "section": SectionResponse.model_validate(section).model_dump(mode="json"),
        },
    )
    return section


@router.delete("/{writing_id}/sections/{section_id}", status_code=204)
async def delete_section(
    writing_id: UUID,
    section_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    op_id: str | None = Depends(_op_id),
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
    await hub.broadcast_writing(
        writing_id,
        {
            "type": "section.deleted",
            "op_id": op_id,
            "section_id": str(section_id),
            "section_ids": list(writing.section_ids or []),
        },
    )


@router.get("/{writing_id}/section-retention")
async def section_retention(
    writing_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Per-section reader drop-off for the outline view.

    Only the writing's author can call this — `_get_user_writing` 404s
    otherwise. Aggregates `reading_progress` rows for the feed item that
    backs this writing: total distinct readers, how many completed, and
    a per-section count of in-progress readers whose `last_section_id`
    points at that section ("stalled here right now").

    A reader is counted at most once: completed readers contribute to
    `completed_readers` only, never to a section bucket. Rows missing
    `last_section_id` (legacy reading_progress before paragraph-precise
    anchors landed) are silently excluded from the per-section bucket
    but still count toward `total_readers`.
    """
    await _get_user_writing(writing_id, user.id, db)

    fi = await db.execute(
        select(FeedItem.id).where(FeedItem.writing_id == writing_id)
    )
    feed_item_id = fi.scalar_one_or_none()
    if feed_item_id is None:
        return {
            "total_readers": 0,
            "completed_readers": 0,
            "sections": [],
        }

    totals = await db.execute(
        select(
            func.count(ReadingProgress.id).label("total"),
            func.count(ReadingProgress.id)
            .filter(ReadingProgress.completed.is_(True))
            .label("completed"),
        ).where(ReadingProgress.feed_item_id == feed_item_id)
    )
    totals_row = totals.one()

    by_section = await db.execute(
        select(
            ReadingProgress.last_section_id,
            func.count(ReadingProgress.id),
        )
        .where(
            ReadingProgress.feed_item_id == feed_item_id,
            ReadingProgress.completed.is_(False),
            ReadingProgress.last_section_id.is_not(None),
        )
        .group_by(ReadingProgress.last_section_id)
    )
    sections = [
        {"section_id": sid, "stalled_count": int(count)}
        for sid, count in by_section.all()
    ]

    return {
        "total_readers": int(totals_row.total or 0),
        "completed_readers": int(totals_row.completed or 0),
        "sections": sections,
    }


async def _get_user_writing(writing_id: UUID, user_id, db: AsyncSession) -> Writing:
    result = await db.execute(
        select(Writing).where(Writing.id == writing_id, Writing.user_id == user_id)
    )
    writing = result.scalar_one_or_none()
    if not writing:
        raise HTTPException(status_code=404, detail="Writing not found")
    return writing
