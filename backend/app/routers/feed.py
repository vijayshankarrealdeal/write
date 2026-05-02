from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import case, func, or_, select, text
from sqlalchemy.dialects.postgresql import array as pg_array
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.types import String

from app.ai.embeddings import schedule_embedding
from app.auth.deps import get_current_user
from app.database import get_db
from app.models.feed_item import FeedItem
from app.models.user import User
from app.models.writing import Writing
from app.notifications import create_notification
from app.realtime import hub
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

# How long a cache row is "fresh enough" to serve. Past this, we fall
# back to the live query — the nightly job is hourly-ish in practice
# but a stale-by-multiple-days cache shouldn't be served either.
_FACET_CACHE_MAX_AGE_HOURS = 48


async def _facet_counts(
    db: AsyncSession,
    column,
    *,
    kind: str,
) -> list[FacetEntry]:
    # 1. Try the cache table first. Stale rows (older than 48h) are
    # treated as missing — better to absorb the live query cost than
    # serve a week-old facet list.
    cache_rows = (await db.execute(
        text(
            "SELECT value, count FROM feed_facets "
            "WHERE kind = :kind "
            "  AND refreshed_at > NOW() - INTERVAL '48 hours' "
            "ORDER BY count DESC LIMIT :lim"
        ).bindparams(kind=kind, lim=_FACET_LIMIT)
    )).all()
    if cache_rows:
        return [
            FacetEntry(value=str(r[0]), count=int(r[1]))
            for r in cache_rows if r[0]
        ]

    # 2. Live query fallback: unnest the array column, group + count.
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
    genres = await _facet_counts(db, FeedItem.genres, kind="genre")
    tags = await _facet_counts(db, FeedItem.tags, kind="tag")
    types = await _facet_counts(db, FeedItem.writing_types, kind="writing_type")
    return FacetResponse(genres=genres, tags=tags, writing_types=types)


# ===== Search ================================================================

# Per-author cap for the diversified result list. Without it a single
# prolific user with the query in every title can monopolise the page.
_SEARCH_PER_AUTHOR_CAP = 3


@router.get("/search", response_model=list[FeedItemResponse])
async def search_feed_items(
    q: str = Query(..., min_length=1, max_length=200),
    limit: int = Query(30, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Diversified search across title, author, description, and the
    tag/genre/writing-type arrays.

    A query like "fantasy" should surface stories whose title contains
    "fantasy", stories tagged with the genre, and authors named that —
    not just title hits. We rank by a coarse relevance score (title >
    author > tag/genre/type > description) and break ties by likes, then
    cap each author at `_SEARCH_PER_AUTHOR_CAP` so one prolific writer
    can't take over the page.
    """
    term = q.strip()
    if not term:
        return []
    pattern = f"%{term}%"
    tag_blob = func.array_to_string(FeedItem.tags, " ")
    genre_blob = func.array_to_string(FeedItem.genres, " ")
    type_blob = func.array_to_string(FeedItem.writing_types, " ")

    score = case(
        (FeedItem.title.ilike(pattern), 100),
        (FeedItem.author.ilike(pattern), 60),
        (tag_blob.ilike(pattern), 45),
        (genre_blob.ilike(pattern), 40),
        (type_blob.ilike(pattern), 35),
        (FeedItem.description.ilike(pattern), 20),
        else_=0,
    ).label("score")

    stmt = (
        select(FeedItem, score)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .where(
            or_(
                FeedItem.title.ilike(pattern),
                FeedItem.author.ilike(pattern),
                FeedItem.description.ilike(pattern),
                tag_blob.ilike(pattern),
                genre_blob.ilike(pattern),
                type_blob.ilike(pattern),
            )
        )
        .order_by(score.desc(), FeedItem.likes_count.desc(), FeedItem.created_at.desc())
        .limit(limit * 4)
    )
    rows = (await db.execute(stmt)).all()

    # Diversify: cap each author so a single user can't dominate. We keep
    # the original score-ordered sequence and skip past the cap; this is
    # cheaper than a SQL window function and the 4x over-fetch above
    # leaves enough headroom to refill from later matches.
    per_author: dict[str, int] = {}
    out: list[FeedItem] = []
    for item, _ in rows:
        key = (item.author or "").lower()
        if per_author.get(key, 0) >= _SEARCH_PER_AUTHOR_CAP:
            continue
        per_author[key] = per_author.get(key, 0) + 1
        out.append(item)
        if len(out) >= limit:
            break
    return out


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


@router.get("/by-writing/{writing_id}", response_model=FeedItemResponse)
async def get_feed_item_by_writing(
    writing_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Resolve the feed card published from a given writing, if any.

    Used by the publish path so a second publish updates the existing card
    instead of creating a duplicate. Only the writing's owner can resolve
    it — drafts are private until published, and even published cards are
    keyed by writing here, which is the author's private id."""
    result = await db.execute(
        select(FeedItem).where(
            FeedItem.writing_id == writing_id,
            FeedItem.author_id == user.id,
        )
    )
    item = result.scalar_one_or_none()
    if not item:
        raise HTTPException(status_code=404, detail="Feed item not found")
    return item


@router.post("/", response_model=FeedItemResponse, status_code=201)
async def create_feed_item(
    data: FeedItemCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    payload = data.model_dump()
    writing_id = payload.get("writing_id")
    if writing_id is not None:
        # Verify the writing exists and belongs to the caller before we
        # take an FK on it — otherwise a malicious client could plant a
        # feed card pointing at someone else's writing and ride the
        # cascade if they ever delete it.
        owner = await db.execute(
            select(Writing.id).where(
                Writing.id == writing_id, Writing.user_id == user.id
            )
        )
        if owner.scalar_one_or_none() is None:
            raise HTTPException(
                status_code=400, detail="writing_id does not belong to user"
            )
        # Idempotency: if a card already exists for this writing, treat
        # the POST as an update so retries on shaky connections don't
        # explode the unique index.
        existing = await db.execute(
            select(FeedItem).where(FeedItem.writing_id == writing_id)
        )
        existing_item = existing.scalar_one_or_none()
        if existing_item is not None:
            for field, value in payload.items():
                if field == "writing_id":
                    continue
                setattr(existing_item, field, value)
            await db.commit()
            await db.refresh(existing_item)
            if not existing_item.is_draft:
                schedule_embedding(existing_item.id)
            return existing_item
    item = FeedItem(
        author=user.name,
        author_id=user.id,
        **payload,
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
    sections_limit: int = Query(
        10,
        ge=0,
        le=2000,
        description=(
            "Number of section bodies to inline. The rest are returned as "
            "title-only stubs (with empty `content`) so the response stays "
            "small for big books — fetch missing bodies via "
            "`GET /api/feed/{id}/sections/{index}`. Pass 0 for titles-only, "
            "or a high number to force full payload."
        ),
    ),
):
    """Return a single feed item.

    For long books (Mahābhārata: 1422 sections), inlining every section's
    Quill content blows up the JSON to ~30 MB and stalls the client. By
    default we now inline only the first `sections_limit` sections; the
    rest are returned with empty content so titles + indices are still
    available, and clients fetch each body lazily as the reader scrolls.
    """
    result = await db.execute(select(FeedItem).where(FeedItem.id == item_id))
    item = result.scalar_one_or_none()
    if not item:
        raise HTTPException(status_code=404, detail="Feed item not found")
    if item.sections:
        # For every section, include a cheap `_has_image` boolean so the
        # frontend can paint an image-dot marker in the chapter list
        # without parsing Quill content. Image embeds in our pipeline are
        # `{"insert": {"image": "..."}}` ops.
        slimmed = list(item.sections)
        for i, raw in enumerate(slimmed):
            s = dict(raw or {})
            ops = s.get("content") or []
            has_img = any(
                isinstance(op, dict)
                and isinstance(op.get("insert"), dict)
                and "image" in op["insert"]
                for op in ops
            )
            s["_has_image"] = has_img
            if sections_limit and i >= sections_limit:
                # Stub out everything beyond `sections_limit` so the payload
                # stays small. Title + has_image are kept; body fetched
                # on demand from /sections/{i}.
                s["content"] = []
                s.pop("canvasData", None)
                s["_lazy"] = True
            slimmed[i] = s
        # SQLAlchemy: mutating `sections` on a queried object would mark it
        # dirty and risk a write-back. Setting via __dict__ keeps it
        # transient on the response only.
        item.__dict__["sections"] = slimmed
    return item


@router.get("/{item_id}/sections/{index}")
async def get_feed_item_section(
    item_id: UUID,
    index: int,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Return one section of a feed item by index. Used by the reader to
    lazy-fetch section bodies for large books, instead of pulling all
    1000+ sections in the initial feed-item response."""
    result = await db.execute(select(FeedItem).where(FeedItem.id == item_id))
    item = result.scalar_one_or_none()
    if not item:
        raise HTTPException(status_code=404, detail="Feed item not found")
    sections = item.sections or []
    if index < 0 or index >= len(sections):
        raise HTTPException(status_code=404, detail="Section index out of range")
    return {"index": index, **(sections[index] or {})}


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
        # Push the new count to anyone watching this post so other
        # clients converge without a refetch.
        await hub.broadcast_feed_item(
            item_id,
            {
                "type": "like.added",
                "likes_count": item.likes_count,
                "actor_id": str(user.id),
            },
        )

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
        await hub.broadcast_feed_item(
            item_id,
            {
                "type": "like.removed",
                "likes_count": item.likes_count,
                "actor_id": str(user.id),
            },
        )

    return {"likes_count": item.likes_count}
