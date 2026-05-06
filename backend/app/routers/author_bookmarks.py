"""Author bookmarks: writer-side flag-this-spot marks inside a draft section.

Distinct from ``routers/bookmarks.py`` (reader-side, anchored to a feed
item). The CRUD shape intentionally mirrors that module so the outbox
treats both kinds the same way:

- Create is idempotent on the (user, section_id, offset) tuple. The
  outbox replays writes when a previous response was lost in flight; a
  strict create would 409 on the second attempt and leave a failed op
  in the queue. The router instead returns the existing row with 200.
- Offset IS patchable here (unlike the reader path). Quill delta math
  in the client recomputes each marker's offset on every edit, and the
  recomputed value is flushed through the outbox.
"""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.author_bookmark import AuthorBookmark
from app.models.user import User
from app.schemas.author_bookmark import (
    AuthorBookmarkCreate,
    AuthorBookmarkPatch,
    AuthorBookmarkResponse,
)

router = APIRouter(prefix="/api/author-bookmarks", tags=["author-bookmarks"])


@router.get("/", response_model=list[AuthorBookmarkResponse])
async def list_author_bookmarks(
    writing_id: UUID | None = None,
    section_id: str | None = None,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """All marks the user owns. ``?writing_id=`` narrows to a single
    project (Inspector "All marks in this project" view). ``?section_id=``
    narrows further to one section (the per-section Inspector tab).
    """

    query = select(AuthorBookmark).where(AuthorBookmark.user_id == user.id)
    if writing_id is not None:
        query = query.where(AuthorBookmark.writing_id == writing_id)
    if section_id is not None:
        query = query.where(AuthorBookmark.section_id == section_id)
    query = query.order_by(
        AuthorBookmark.section_id.asc(),
        AuthorBookmark.offset.asc(),
    )
    result = await db.execute(query)
    return result.scalars().all()


@router.post("/", response_model=AuthorBookmarkResponse)
async def create_author_bookmark(
    data: AuthorBookmarkCreate,
    response: Response,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # Dedupe at the application layer — (user, section_id, offset) is the
    # natural key the UI exposes, so an exact match should round-trip
    # rather than 409.
    existing = await db.execute(
        select(AuthorBookmark).where(
            and_(
                AuthorBookmark.user_id == user.id,
                AuthorBookmark.section_id == data.section_id,
                AuthorBookmark.offset == data.offset,
            )
        )
    )
    found = existing.scalar_one_or_none()
    if found is not None:
        dirty = False
        if data.label is not None and data.label != found.label:
            found.label = data.label
            dirty = True
        if data.color and data.color != found.color:
            found.color = data.color
            dirty = True
        if data.writing_id and data.writing_id != found.writing_id:
            found.writing_id = data.writing_id
            dirty = True
        if dirty:
            await db.commit()
            await db.refresh(found)
        response.status_code = status.HTTP_200_OK
        return found

    bookmark = AuthorBookmark(
        user_id=user.id,
        writing_id=data.writing_id,
        section_id=data.section_id,
        offset=data.offset,
        label=data.label,
        color=data.color or "#FFB300",
    )
    db.add(bookmark)
    await db.commit()
    await db.refresh(bookmark)
    response.status_code = status.HTTP_201_CREATED
    return bookmark


@router.patch("/{bookmark_id}", response_model=AuthorBookmarkResponse)
async def patch_author_bookmark(
    bookmark_id: UUID,
    data: AuthorBookmarkPatch,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(AuthorBookmark).where(
            AuthorBookmark.id == bookmark_id,
            AuthorBookmark.user_id == user.id,
        )
    )
    bookmark = result.scalar_one_or_none()
    if bookmark is None:
        raise HTTPException(status_code=404, detail="Author bookmark not found")

    if data.label is not None:
        bookmark.label = data.label
    if data.color is not None:
        bookmark.color = data.color
    if data.offset is not None:
        bookmark.offset = data.offset

    await db.commit()
    await db.refresh(bookmark)
    return bookmark


@router.delete("/{bookmark_id}", status_code=204)
async def delete_author_bookmark(
    bookmark_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(AuthorBookmark).where(
            AuthorBookmark.id == bookmark_id,
            AuthorBookmark.user_id == user.id,
        )
    )
    bookmark = result.scalar_one_or_none()
    if bookmark is None:
        # Idempotent — outbox replays of a successful prior delete are no-ops.
        return
    await db.delete(bookmark)
    await db.commit()
