from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from sqlalchemy import case, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.bookshelf import Bookshelf
from app.models.feed_item import FeedItem
from app.models.reading_progress import ReadingProgress
from app.models.user import User
from app.schemas.reading import (
    ContinueReadingItem,
    LibraryBook,
    LibraryCounts,
    LibraryLabel,
    ReadingProgressResponse,
    ReadingProgressUpdate,
)

router = APIRouter(prefix="/api/reading-progress", tags=["reading"])


@router.get("/continue-reading", response_model=list[ContinueReadingItem])
async def continue_reading(
    limit: int = Query(8, ge=1, le=24),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Items the user has started but not finished, newest activity first.

    Joined with `feed_items` so the rail can render a cover + title in
    one round trip. Completed items are excluded — they belong on a
    "finished" rail, not the resume one.
    """

    query = (
        select(
            FeedItem.id.label("feed_item_id"),
            FeedItem.title,
            FeedItem.author,
            FeedItem.image_url,
            FeedItem.image_meta,
            ReadingProgress.scroll_position,
            ReadingProgress.last_read_at,
            ReadingProgress.last_section_id,
            ReadingProgress.last_anchor,
            ReadingProgress.completed,
        )
        .join(FeedItem, FeedItem.id == ReadingProgress.feed_item_id)
        .where(
            ReadingProgress.user_id == user.id,
            ReadingProgress.completed.is_(False),
            ReadingProgress.last_read_at.is_not(None),
        )
        .order_by(ReadingProgress.last_read_at.desc())
        .limit(limit)
    )
    result = await db.execute(query)
    return [
        ContinueReadingItem(
            feed_item_id=row.feed_item_id,
            title=row.title,
            author=row.author,
            image_url=row.image_url,
            image_meta=row.image_meta,
            scroll_position=row.scroll_position,
            last_read_at=row.last_read_at,
            last_section_id=row.last_section_id,
            last_anchor=row.last_anchor,
            completed=row.completed,
        )
        for row in result.all()
    ]


# ---------------------------------------------------------------------------
# Library — bucketed view across reading_progress + bookshelves.
#
# The Library tab is the home for "everything I've touched": books I'm
# reading, books I've saved, books I've finished. The shape is the same
# regardless of tab so the Flutter side renders one grid; ``label`` per
# row drives the colored chip in the corner.
#
# Bucket rules (computed in SQL so pagination + counts stay cheap):
#   finished  — ReadingProgress.completed = True
#   reading   — ReadingProgress.completed = False AND last_read_at IS NOT NULL
#   abandoned — reading, but last_read_at older than 30 days AND
#               scroll_position < 0.8 (a soft signal; UI may suppress it)
#   saved     — present in any of the user's bookshelves but no progress
#               row (the user added it to a shelf but never opened it).
#               A book the user has *both* shelved *and* started shows
#               up under reading/finished, not saved — progress wins so
#               the rail isn't duplicated.
# ---------------------------------------------------------------------------

_ABANDON_DAYS = 30
_ABANDON_SCROLL = 0.80


def _label_expr():
    """SQL expression that derives a label from progress columns.

    Returns NULL for rows that have no progress (the saved-only path is
    handled by the bookshelves union below).
    """
    return case(
        (ReadingProgress.completed.is_(True), "finished"),
        (
            (ReadingProgress.last_read_at.is_not(None))
            & (
                func.extract("epoch", func.now() - ReadingProgress.last_read_at)
                > _ABANDON_DAYS * 86400
            )
            & (func.coalesce(ReadingProgress.scroll_position, 0.0) < _ABANDON_SCROLL),
            "abandoned",
        ),
        (ReadingProgress.last_read_at.is_not(None), "reading"),
        else_=None,
    )


async def _library_items_query(db: AsyncSession, user_id: UUID, label: LibraryLabel):
    """Build a per-label SELECT joining progress + feed_items + shelves.

    Returns a list of `LibraryBook`-shaped dicts ready to feed Pydantic.
    """
    label_expr = _label_expr().label("label")

    progress_select = (
        select(
            FeedItem.id.label("feed_item_id"),
            FeedItem.writing_id.label("writing_id"),
            FeedItem.title,
            FeedItem.author,
            FeedItem.image_url,
            FeedItem.image_meta,
            ReadingProgress.scroll_position,
            ReadingProgress.last_read_at,
            ReadingProgress.last_section_id,
            ReadingProgress.last_anchor,
            ReadingProgress.finished_at,
            label_expr,
        )
        .join(FeedItem, FeedItem.id == ReadingProgress.feed_item_id)
        .where(ReadingProgress.user_id == user_id)
    )

    # `saved` = on a shelf but no reading_progress row. We resolve this
    # by pulling the union of feed_item ids across the user's shelves,
    # then anti-joining against reading_progress.
    shelf_rows = (
        await db.execute(
            select(Bookshelf.id, Bookshelf.name, Bookshelf.item_ids).where(
                Bookshelf.user_id == user_id
            )
        )
    ).all()
    # Build {feed_item_id: (shelf_id, shelf_name)} — first-shelf wins if a
    # book is on multiple shelves (rare; the chip only carries one name).
    saved_meta: dict[str, tuple[UUID, str]] = {}
    saved_ids: list[str] = []
    for shelf_id, shelf_name, item_ids in shelf_rows:
        for fid in item_ids or []:
            if fid and fid not in saved_meta:
                saved_meta[fid] = (shelf_id, shelf_name)
                saved_ids.append(fid)

    out: list[LibraryBook] = []

    # 1) Books with a reading_progress row — already labeled by SQL.
    if label != "saved":
        rows = (await db.execute(progress_select)).all()
        for r in rows:
            row_label = r.label
            if row_label is None:
                # No last_read_at AND not completed → treat as `saved`
                # only if the book also lives on a shelf. Otherwise skip.
                if str(r.feed_item_id) in saved_meta:
                    row_label = "saved"
                else:
                    continue
            if label != "all" and row_label != label:
                continue
            shelf = saved_meta.get(str(r.feed_item_id))
            out.append(LibraryBook(
                feed_item_id=r.feed_item_id,
                writing_id=r.writing_id,
                title=r.title,
                author=r.author,
                image_url=r.image_url,
                image_meta=r.image_meta,
                label=row_label,
                scroll_position=r.scroll_position,
                last_read_at=r.last_read_at,
                last_section_id=r.last_section_id,
                last_anchor=r.last_anchor,
                finished_at=r.finished_at,
                shelf_id=shelf[0] if shelf else None,
                shelf_name=shelf[1] if shelf else None,
            ))

    # 2) Shelved books with NO reading_progress → `saved` label.
    progressed_ids: set[str] = {str(b.feed_item_id) for b in out}
    if label in ("saved", "all") and saved_ids:
        missing = [fid for fid in saved_ids if fid not in progressed_ids]
        if missing:
            shelved_rows = (
                await db.execute(
                    select(
                        FeedItem.id.label("feed_item_id"),
                        FeedItem.writing_id.label("writing_id"),
                        FeedItem.title,
                        FeedItem.author,
                        FeedItem.image_url,
                        FeedItem.image_meta,
                    ).where(FeedItem.id.in_(missing))
                )
            ).all()
            for r in shelved_rows:
                shelf = saved_meta.get(str(r.feed_item_id))
                out.append(LibraryBook(
                    feed_item_id=r.feed_item_id,
                    writing_id=r.writing_id,
                    title=r.title,
                    author=r.author,
                    image_url=r.image_url,
                    image_meta=r.image_meta,
                    label="saved",
                    shelf_id=shelf[0] if shelf else None,
                    shelf_name=shelf[1] if shelf else None,
                ))

    # Stable ordering: finished by finished_at desc; reading by last_read_at
    # desc; saved by feed_item_id desc as a fallback. ``all`` mixes them
    # by whichever timestamp the row has, finished_at preferred when
    # present, else last_read_at, else "very old" so saved rows trail.
    def _sort_key(b: LibraryBook):
        anchor = b.finished_at or b.last_read_at
        # Sort newest first; saved-only rows (anchor=None) drop to the end.
        return (-(anchor.timestamp() if anchor else 0),)

    out.sort(key=_sort_key)
    return out


@router.get("/library", response_model=list[LibraryBook])
async def library(
    label: LibraryLabel = Query("all"),
    limit: int = Query(60, ge=1, le=200),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The user's bookcase, bucketed.

    Backs the new Library page (`/library` in the Flutter router). One
    response per tab — the client passes ``label=reading|saved|finished``
    or ``all`` for the All tab. Sort is newest-activity-first; saved-only
    rows trail (they don't have a timestamp).
    """
    items = await _library_items_query(db, user.id, label)
    return items[:limit]


@router.get("/library-counts", response_model=LibraryCounts)
async def library_counts(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Per-label counts for the Library tab badges.

    Cheap — two aggregate queries (one over reading_progress, one over
    bookshelves). The tab strip in the Flutter Library page renders
    "Reading (3) · Finished (12) · Saved (5)" from this.
    """
    # Counts derived directly from the labelled rows. Use the same SQL
    # CASE so any future tweak (e.g. abandoned threshold) stays in one
    # place.
    label_expr = _label_expr()
    grouped = (
        await db.execute(
            select(label_expr.label("label"), func.count().label("n"))
            .where(ReadingProgress.user_id == user.id)
            .group_by(label_expr)
        )
    ).all()
    counts: dict[str, int] = {"reading": 0, "finished": 0, "abandoned": 0, "saved": 0}
    for row in grouped:
        if row.label in counts:
            counts[row.label] = int(row.n or 0)

    # Saved = shelved AND no reading_progress row.
    shelf_rows = (
        await db.execute(
            select(Bookshelf.item_ids).where(Bookshelf.user_id == user.id)
        )
    ).all()
    saved_ids = {fid for row in shelf_rows for fid in (row[0] or []) if fid}
    progressed_ids = (
        await db.execute(
            select(ReadingProgress.feed_item_id).where(ReadingProgress.user_id == user.id)
        )
    ).scalars().all()
    progressed_set = {str(pid) for pid in progressed_ids}
    counts["saved"] = sum(1 for fid in saved_ids if fid not in progressed_set)

    counts["all"] = counts["reading"] + counts["finished"] + counts["abandoned"] + counts["saved"]
    return LibraryCounts(**counts)


@router.get("/{feed_item_id}", response_model=ReadingProgressResponse | None)
async def get_reading_progress(
    feed_item_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(ReadingProgress).where(
            ReadingProgress.user_id == user.id,
            ReadingProgress.feed_item_id == feed_item_id,
        )
    )
    return result.scalar_one_or_none()


@router.put("/{feed_item_id}", response_model=ReadingProgressResponse)
async def upsert_reading_progress(
    feed_item_id: UUID,
    data: ReadingProgressUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Update the user's progress on this feed item.

    Idempotent: a new row is created on first touch; subsequent calls
    refresh fields the client passed. ``finished_at`` is stamped the
    first time ``completed`` transitions false → true so the Library /
    Finished history view can render "you finished this on X" without
    reaching for ``last_read_at`` as a proxy.
    """
    result = await db.execute(
        select(ReadingProgress).where(
            ReadingProgress.user_id == user.id,
            ReadingProgress.feed_item_id == feed_item_id,
        )
    )
    progress = result.scalar_one_or_none()

    if progress is None:
        progress = ReadingProgress(
            user_id=user.id,
            feed_item_id=feed_item_id,
        )
        db.add(progress)

    was_completed = bool(progress.completed)
    if data.scroll_position is not None:
        progress.scroll_position = data.scroll_position
    if data.completed is not None:
        progress.completed = data.completed
        # First-time finish only — re-completing (e.g. user un-checks
        # and re-checks) keeps the original finished_at so the history
        # timestamp doesn't jitter.
        if data.completed and not was_completed and progress.finished_at is None:
            progress.finished_at = datetime.now(UTC)
    if data.last_section_id is not None:
        progress.last_section_id = data.last_section_id
    if data.last_anchor is not None:
        progress.last_anchor = data.last_anchor
    progress.last_read_at = datetime.now(UTC)

    await db.commit()
    await db.refresh(progress)

    # Reading progress shifts the user's profile (completed boosts the
    # genre weight; abandoned penalises it). Drop the cache so the next
    # /api/ai/recommendations call rebuilds with fresh signals.
    from app.ai.recommendation import invalidate_user_profile_cache
    invalidate_user_profile_cache(user.id)

    return progress
