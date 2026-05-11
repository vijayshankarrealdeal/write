from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import case, func, or_, select, text
from sqlalchemy.dialects.postgresql import array as pg_array
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.types import String

from app.ai.embeddings import schedule_embedding
from app.auth.deps import get_current_user
from app.database import get_db
from app.feed_home import compose_home
from app.feed_publish import upsert_feed_item_for_writing
from app.feed_sections import (
    get_section_content,
    list_section_stubs,
    section_id_at_index,
    set_free_preview_section_ids,
    set_published_section_ids,
)
from app.feed_visibility import public_feed_clause, visibility_clause
from app.models.feed_item import FeedItem
from app.models.purchase import Purchase
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
    HomeRail,
)

router = APIRouter(prefix="/api/feed", tags=["feed"])


async def _user_purchased_ids(
    db: AsyncSession, user_id: UUID, item_ids: list[UUID]
) -> set[UUID]:
    """Return the subset of [item_ids] this user has purchased.

    One round-trip to fold `purchased=True` onto a list of feed items.
    Used by the listing endpoints so a paid book the user has bought
    shows the right chip without per-item access calls.
    """
    if not item_ids:
        return set()
    rows = (
        await db.execute(
            select(Purchase.feed_item_id).where(
                Purchase.user_id == user_id,
                Purchase.feed_item_id.in_(item_ids),
            )
        )
    ).all()
    return {r[0] for r in rows}


def _annotate_purchased(
    items: list[FeedItem], user_id: UUID, purchased_ids: set[UUID]
) -> list[FeedItem]:
    """Stamp `purchased: bool` onto each item via __dict__ so the
    Pydantic response picks it up without an ORM column.

    The author always sees their own items as `purchased=True` so the
    Buy button never appears on their own publishes."""
    for item in items:
        owns = item.author_id == user_id or item.id in purchased_ids
        item.__dict__["purchased"] = owns
    return items


async def _annotate_listing_purchased(
    db: AsyncSession, items: list[FeedItem], user_id: UUID
) -> list[FeedItem]:
    """Per-listing helper: skip the round-trip when no item is paid."""
    paid_ids = [it.id for it in items if (it.price_cents or 0) > 0]
    purchased = await _user_purchased_ids(db, user_id, paid_ids)
    return _annotate_purchased(items, user_id, purchased)


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


@router.get("/home", response_model=list[HomeRail])
async def get_home_feed(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Single-call home feed composed of multiple rails.

    Rails (in display order, also dedup priority):

      * Featured              — top engagement of the last 30 days
      * Continue Reading      — user's unfinished `ReadingProgress` rows
      * New Releases          — last 7 days, newest first
      * For You               — personalised via `recommend_for_user`
      * Trending Now          — last 14 days, weighted likes + comments
      * Top 10 This Week      — last 7 days, pure likes
      * Discover Hidden Gems  — recent, low likes (1–30) + has comments
      * Editor's Picks        — high engagement (5+ comments AND 20+ likes)

    A book that qualifies for two rails appears only in the higher one
    (so the user never scrolls past the same item twice). Empty rails
    are dropped from the response. Each rail strips the heavy
    `sections` JSONB; clients read full chapters via
    `GET /api/feed/{id}/sections/{i}` on tap-through.

    Privacy is enforced both at the per-generator level and in a final
    materialization gate, so a private writing only surfaces to its
    author or an approved follower.
    """
    return await compose_home(user, db)


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
    # `public_feed_clause` combines `is_draft = False` with the per-writing
    # visibility gate (public OR own OR approved follower) so private
    # writings only surface to viewers the author has approved.
    query = select(FeedItem).where(public_feed_clause(user.id))

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
    items = list(result.scalars().all())
    return await _annotate_listing_purchased(db, items, user.id)


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
        .where(public_feed_clause(user.id))
        .where(FeedItem.tags.op("&&")(pg_array([tag], type_=String)))
    )
    query = _apply_sort(query, sort)
    cursor_item = await _resolve_cursor(cursor, db)
    if cursor_item is not None:
        query = _apply_cursor(query, sort, cursor_item)
    query = query.limit(limit)
    result = await db.execute(query)
    items = list(result.scalars().all())
    return await _annotate_listing_purchased(db, items, user.id)


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
        .where(public_feed_clause(user.id))
        .where(FeedItem.genres.op("&&")(pg_array([genre], type_=String)))
    )
    query = _apply_sort(query, sort)
    cursor_item = await _resolve_cursor(cursor, db)
    if cursor_item is not None:
        query = _apply_cursor(query, sort, cursor_item)
    query = query.limit(limit)
    result = await db.execute(query)
    items = list(result.scalars().all())
    return await _annotate_listing_purchased(db, items, user.id)


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
    # Facets are a global discovery surface, so they only count *public*
    # items — private writings stay out of the chip suggestions even for
    # viewers who could read them. Per-viewer facet aggregation would
    # break caching and bloat the response. The nightly cache builder
    # should apply the same `visibility = 'public'` filter.
    val = func.unnest(column).label("value")
    stmt = (
        select(val, func.count().label("count"))
        .where(FeedItem.is_draft == False)  # noqa: E712
        .where(FeedItem.visibility == "public")
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
        .where(public_feed_clause(user.id))
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
    return await _annotate_listing_purchased(db, out, user.id)


@router.get("/by-author/{author_id}", response_model=list[FeedItemResponse])
async def list_feed_by_author(
    author_id: UUID,
    include_drafts: bool = False,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    query = select(FeedItem).where(FeedItem.author_id == author_id)
    if author_id == user.id:
        # Author viewing their own profile sees everything they own,
        # including drafts (when requested) and private items.
        if not include_drafts:
            query = query.where(FeedItem.is_draft == False)  # noqa: E712
    else:
        # Other viewers: drafts are never shown, and private writings
        # are gated by approved-follow.
        query = query.where(FeedItem.is_draft == False)  # noqa: E712
        query = query.where(visibility_clause(user.id))
    query = query.order_by(FeedItem.created_at.desc())
    result = await db.execute(query)
    items = list(result.scalars().all())
    return await _annotate_listing_purchased(db, items, user.id)


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
    item.__dict__["purchased"] = True
    return item


@router.post("/", response_model=FeedItemResponse, status_code=201)
async def create_feed_item(
    data: FeedItemCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    payload = data.model_dump()
    writing_id = payload.pop("writing_id", None)
    # The author's curated chapter set — handled separately from the
    # FeedItem fields because it touches the `sections` table directly.
    published_section_ids = payload.pop("published_section_ids", None)
    free_preview_section_ids = payload.pop("free_preview_section_ids", None)
    # Section bodies are owned by the `sections` table, not the feed
    # card. Discard any incoming `sections` field — old clients still
    # send it from cached state.
    payload.pop("sections", None)
    if writing_id is None:
        # The frontend sends writing_id on every publish; rejecting the
        # request here is what guarantees every feed card has the
        # source-writing FK and so participates in the ON DELETE CASCADE.
        raise HTTPException(
            status_code=400, detail="writing_id is required"
        )
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
    # Pricing gate: a positive price requires the calling author to
    # have completed Razorpay onboarding, otherwise the Route transfer
    # would fail at capture time and strand readers in a broken buy
    # flow. Free publishes (price_cents <= 0) bypass this entirely.
    if (payload.get("price_cents") or 0) > 0 and not user.razorpay_charges_enabled:
        raise HTTPException(
            status_code=409,
            detail="Finish Razorpay payouts setup before pricing a book.",
        )
    # Author's curation step: flip per-section is_published bits before
    # we upsert the feed card so a reader hitting the listing endpoints
    # immediately after publish sees a consistent (chapter list, card)
    # pair. Done in the same transaction as the upsert below.
    if published_section_ids is not None:
        await set_published_section_ids(
            db,
            writing_id=writing_id,
            published_ids=published_section_ids,
        )
    if free_preview_section_ids is not None:
        await set_free_preview_section_ids(
            db,
            writing_id=writing_id,
            preview_ids=free_preview_section_ids,
        )
    item = await upsert_feed_item_for_writing(
        db,
        writing_id=writing_id,
        publisher=user,
        **payload,
    )
    item.__dict__["purchased"] = True
    return item


@router.get("/{item_id}", response_model=FeedItemResponse)
async def get_feed_item(
    item_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Return a single feed item with its chapter list.

    `sections` is an ordered list of stubs — `{section_id, title,
    updated_at, _has_image, _lazy: True}` — sourced live from the
    `sections` table via `Writing.section_ids[]`. No chapter bodies are
    inlined; clients fetch each body lazily via
    `GET /api/feed/{id}/sections/{section_id}` (or the legacy
    `/sections/{index}` endpoint). Section bodies live in one place
    now — the `sections` table — so author edits propagate to readers
    without a republish, and the response stays bounded for thousand-
    chapter books.

    `updated_at` on each stub lets the client diff against its cache to
    flag chapters that changed since last open ("Updated 2h ago").
    """
    # Author can always read their own items (drafts + private). Everyone
    # else must clear the public/visibility gate. We return 404 (not 403)
    # for hidden items so we don't reveal that the row exists.
    result = await db.execute(
        select(FeedItem).where(
            FeedItem.id == item_id,
            or_(
                FeedItem.author_id == user.id,
                public_feed_clause(user.id),
            ),
        )
    )
    item = result.scalar_one_or_none()
    if not item:
        raise HTTPException(status_code=404, detail="Feed item not found")
    if item.writing_id is not None:
        stubs = await list_section_stubs(db, item.writing_id)
    else:
        stubs = []
    # Transient response field — bypass the ORM so SQLAlchemy doesn't try
    # to write the stubs list back to (the now-removed) `sections` JSONB.
    item.__dict__["sections"] = stubs
    item.__dict__["purchased"] = await _viewer_owns(db, user, item)
    return item


async def _viewer_owns(db: AsyncSession, user: User, item: FeedItem) -> bool:
    """True iff the viewer is the author or has a Purchase row for the
    item. Free books always read as `purchased=True` so the client UI
    treats them as fully unlocked.
    """
    if (item.price_cents or 0) <= 0:
        return True
    if item.author_id == user.id:
        return True
    row = await db.execute(
        select(Purchase.id).where(
            Purchase.user_id == user.id,
            Purchase.feed_item_id == item.id,
        )
    )
    return row.scalar_one_or_none() is not None


async def _load_visible_feed_item(
    db: AsyncSession, user: User, item_id: UUID
) -> FeedItem:
    """Helper: load a FeedItem the viewer is authorized to read.

    404 (not 403) for hidden rows so we don't leak existence of
    private writings. Used by the per-section endpoints to avoid
    duplicating the visibility predicate across handlers.
    """
    result = await db.execute(
        select(FeedItem).where(
            FeedItem.id == item_id,
            or_(
                FeedItem.author_id == user.id,
                public_feed_clause(user.id),
            ),
        )
    )
    item = result.scalar_one_or_none()
    if not item:
        raise HTTPException(status_code=404, detail="Feed item not found")
    return item


@router.get("/{item_id}/sections/by-id/{section_id}")
async def get_feed_item_section_by_id(
    item_id: UUID,
    section_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Return one section by stable UUID. Use this endpoint for
    pagination — section UUIDs survive author edits (insert / delete /
    reorder) so a reader on chapter X stays on chapter X even after
    the author shuffles the chapter list. Body is read live from the
    `sections` table; author errata reach the reader on the next fetch.

    For paid books, non-owner viewers only get bodies for sections the
    author has flagged as a free preview — every other section comes
    back as `{locked: true, content: null}` so the client renders a
    Buy CTA in place of the chapter body.
    """
    item = await _load_visible_feed_item(db, user, item_id)
    if item.writing_id is None:
        raise HTTPException(status_code=404, detail="Section not found")
    preview_only = not await _viewer_owns(db, user, item)
    section = await get_section_content(
        db,
        writing_id=item.writing_id,
        section_id=section_id,
        preview_only=preview_only,
    )
    if section is None:
        raise HTTPException(status_code=404, detail="Section not found")
    return section


@router.get("/{item_id}/sections/{index}")
async def get_feed_item_section(
    item_id: UUID,
    index: int,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Return one section by integer index — legacy URL shape kept
    alive so the existing Flutter client doesn't break during the
    UUID-pagination migration. New clients should call
    `GET /api/feed/{id}/sections/by-id/{section_id}` instead, which is
    stable across author edits.
    """
    item = await _load_visible_feed_item(db, user, item_id)
    if item.writing_id is None:
        raise HTTPException(status_code=404, detail="Section index out of range")
    sid = await section_id_at_index(db, item.writing_id, index)
    if sid is None:
        raise HTTPException(status_code=404, detail="Section index out of range")
    preview_only = not await _viewer_owns(db, user, item)
    section = await get_section_content(
        db,
        writing_id=item.writing_id,
        section_id=sid,
        preview_only=preview_only,
    )
    if section is None:
        raise HTTPException(status_code=404, detail="Section not found")
    return {"index": index, **section}


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
    # Author re-curating chapters — bulk-flip is_published before
    # mutating other fields so the per-section state is consistent
    # with the resulting FeedItem.
    published_section_ids = payload.pop("published_section_ids", None)
    if published_section_ids is not None and item.writing_id is not None:
        await set_published_section_ids(
            db,
            writing_id=item.writing_id,
            published_ids=published_section_ids,
        )
    free_preview_section_ids = payload.pop("free_preview_section_ids", None)
    if free_preview_section_ids is not None and item.writing_id is not None:
        await set_free_preview_section_ids(
            db,
            writing_id=item.writing_id,
            preview_ids=free_preview_section_ids,
        )
    # Same gate as create — a positive price requires Razorpay onboarding.
    if "price_cents" in payload and (payload["price_cents"] or 0) > 0:
        if not user.razorpay_charges_enabled:
            raise HTTPException(
                status_code=409,
                detail="Finish Razorpay payouts setup before pricing a book.",
            )
        payload["price_cents"] = max(0, int(payload["price_cents"]))
    if "currency" in payload and payload["currency"]:
        payload["currency"] = payload["currency"].lower()[:8]
    # Section bodies live in the `sections` table — old clients still
    # send `sections` from cached publish state, but we ignore it here.
    payload.pop("sections", None)
    for field, value in payload.items():
        if field in {"title", "description"} and getattr(item, field) != value:
            text_changed = True
        setattr(item, field, value)
    await db.commit()
    await db.refresh(item)
    item.__dict__["purchased"] = True
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
    result = await db.execute(
        select(FeedItem).where(
            FeedItem.id == item_id,
            or_(
                FeedItem.author_id == user.id,
                public_feed_clause(user.id),
            ),
        )
    )
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
    result = await db.execute(
        select(FeedItem).where(
            FeedItem.id == item_id,
            or_(
                FeedItem.author_id == user.id,
                public_feed_clause(user.id),
            ),
        )
    )
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
