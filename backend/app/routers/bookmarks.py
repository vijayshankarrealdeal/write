"""Bookmarks: named in-text marks the user can return to.

The CRUD shape mirrors `highlights.py` for consistency, with two
differences worth flagging:

- Create is *idempotent* on the (user, feed_item, section_index, anchor)
  tuple. The outbox replays writes when a previous response was lost in
  flight; a strict create would 409 on the second attempt and leave a
  failed op in the user's queue. The router instead returns the existing
  row with status 200.
- Anchor is paragraph-precise (paragraph_idx + char_offset) so the mark
  survives reflow on font-size or column-width changes; raw scroll
  position is left to `reading_progress`.
"""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.bookmark import Bookmark
from app.models.user import User
from app.schemas.bookmark import (
    BookmarkCreate,
    BookmarkPatch,
    BookmarkResponse,
)

router = APIRouter(prefix="/api/bookmarks", tags=["bookmarks"])


def _anchor_dict(payload: BookmarkCreate) -> dict:
    return {
        "paragraph_idx": payload.anchor.paragraph_idx,
        "char_offset": payload.anchor.char_offset,
    }


@router.get("/", response_model=list[BookmarkResponse])
async def list_bookmarks(
    feed_item_id: UUID | None = None,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """All bookmarks for the user, newest first.

    `?feed_item_id=` narrows to a single writing — used by the reader to
    render in-margin tabs without paging through the global list.
    """

    query = select(Bookmark).where(Bookmark.user_id == user.id)
    if feed_item_id is not None:
        query = query.where(Bookmark.feed_item_id == feed_item_id)
    query = query.order_by(Bookmark.updated_at.desc())
    result = await db.execute(query)
    return result.scalars().all()


@router.get("/by-feed-item/{feed_item_id}", response_model=list[BookmarkResponse])
async def list_bookmarks_for_feed_item(
    feed_item_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Convenience alias the reader hits when opening a writing — keeps
    the URL stable even if the global list path moves."""

    result = await db.execute(
        select(Bookmark)
        .where(
            Bookmark.user_id == user.id,
            Bookmark.feed_item_id == feed_item_id,
        )
        .order_by(Bookmark.section_index.asc(), Bookmark.created_at.asc())
    )
    return result.scalars().all()


@router.post("/", response_model=BookmarkResponse)
async def create_bookmark(
    data: BookmarkCreate,
    response: Response,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    anchor = _anchor_dict(data)

    # Dedupe at the application layer — the JSONB column can't sit in a
    # btree unique index by itself, but the (user, item, section_index,
    # anchor) tuple is what the UI exposes, so an exact match should
    # round-trip rather than 409.
    existing = await db.execute(
        select(Bookmark).where(
            and_(
                Bookmark.user_id == user.id,
                Bookmark.feed_item_id == data.feed_item_id,
                Bookmark.section_index == data.section_index,
                Bookmark.anchor == anchor,
            )
        )
    )
    found = existing.scalar_one_or_none()
    if found is not None:
        # Update mutable fields if the client sent fresh values; treat
        # the call as an upsert.
        dirty = False
        if data.label is not None and data.label != found.label:
            found.label = data.label
            dirty = True
        if data.color and data.color != found.color:
            found.color = data.color
            dirty = True
        if data.section_id and data.section_id != found.section_id:
            found.section_id = data.section_id
            dirty = True
        if dirty:
            await db.commit()
            await db.refresh(found)
        response.status_code = status.HTTP_200_OK
        return found

    bookmark = Bookmark(
        user_id=user.id,
        feed_item_id=data.feed_item_id,
        section_id=data.section_id,
        section_index=data.section_index,
        anchor=anchor,
        label=data.label,
        color=data.color or "#FFB300",
    )
    db.add(bookmark)
    await db.commit()
    await db.refresh(bookmark)
    response.status_code = status.HTTP_201_CREATED
    return bookmark


@router.patch("/{bookmark_id}", response_model=BookmarkResponse)
async def patch_bookmark(
    bookmark_id: UUID,
    data: BookmarkPatch,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Bookmark).where(
            Bookmark.id == bookmark_id,
            Bookmark.user_id == user.id,
        )
    )
    bookmark = result.scalar_one_or_none()
    if bookmark is None:
        raise HTTPException(status_code=404, detail="Bookmark not found")

    if data.label is not None:
        bookmark.label = data.label
    if data.color is not None:
        bookmark.color = data.color

    await db.commit()
    await db.refresh(bookmark)
    return bookmark


@router.delete("/{bookmark_id}", status_code=204)
async def delete_bookmark(
    bookmark_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Bookmark).where(
            Bookmark.id == bookmark_id,
            Bookmark.user_id == user.id,
        )
    )
    bookmark = result.scalar_one_or_none()
    if bookmark is None:
        # Idempotent delete — outbox replays should not fail on a missing row.
        return
    await db.delete(bookmark)
    await db.commit()
