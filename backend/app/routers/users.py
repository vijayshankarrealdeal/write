from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.exc import IntegrityError

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.block import Block
from app.models.feed_item import FeedItem
from app.models.follow import Follow
from app.models.user import User
from app.notifications import create_notification
from app.schemas.user import ListUpdateRequest, UserResponse, UserUpdate

router = APIRouter(prefix="/api/users", tags=["users"])


class PublicUser(BaseModel):
    """Slim user record for search results / public profile listings.

    Excludes private fields (email, lists, onboarding state) that are
    only relevant to the user themselves.
    """

    id: UUID
    name: str | None
    photo_url: str | None
    photo_meta: dict | None = None
    posts_count: int = 0
    followers_count: int = 0
    following_count: int = 0
    is_following: bool = False
    is_blocked: bool = False

    model_config = {"from_attributes": True}


def _follower_count_subquery(target_col):
    return (
        select(func.count(Follow.id))
        .where(Follow.followee_id == target_col)
        .correlate(User)
        .scalar_subquery()
    )


def _following_count_subquery(target_col):
    return (
        select(func.count(Follow.id))
        .where(Follow.follower_id == target_col)
        .correlate(User)
        .scalar_subquery()
    )


@router.get("/me", response_model=UserResponse)
async def get_profile(user: User = Depends(get_current_user)):
    return user


@router.get("/search", response_model=list[PublicUser])
async def search_users(
    q: str = Query(..., min_length=1, max_length=200),
    limit: int = Query(20, ge=1, le=50),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Fuzzy author search by display name. Joins published-post counts
    so the client can surface "X stories" next to each result and rank
    productive authors above empty profiles."""
    term = q.strip()
    if not term:
        return []
    pattern = f"%{term}%"
    posts_count = (
        select(func.count(FeedItem.id))
        .where(FeedItem.author_id == User.id)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .correlate(User)
        .scalar_subquery()
    )
    followers_count = _follower_count_subquery(User.id)
    following_count = _following_count_subquery(User.id)
    invisible = await _viewer_invisible_to(db, user.id)
    stmt = (
        select(
            User,
            posts_count.label("posts_count"),
            followers_count.label("followers_count"),
            following_count.label("following_count"),
        )
        .where(User.name.is_not(None))
        .where(User.name.ilike(pattern))
        .order_by(posts_count.desc(), User.name.asc())
        .limit(limit)
    )
    if invisible:
        stmt = stmt.where(User.id.notin_(invisible))
    rows = (await db.execute(stmt)).all()
    target_ids = [u.id for u, *_ in rows]
    following_set = await _following_set(db, user.id, target_ids)
    return [
        PublicUser(
            id=u.id,
            name=u.name,
            photo_url=u.photo_url,
            photo_meta=u.photo_meta,
            posts_count=int(p or 0),
            followers_count=int(fc or 0),
            following_count=int(gc or 0),
            is_following=u.id in following_set,
        )
        for u, p, fc, gc in rows
    ]


async def _following_set(
    db: AsyncSession, viewer_id: UUID, target_ids: list[UUID]
) -> set[UUID]:
    """Return the subset of `target_ids` that `viewer_id` follows.

    One round-trip instead of N — keeps search results O(1) DB hits.
    """
    if not target_ids:
        return set()
    rows = await db.execute(
        select(Follow.followee_id).where(
            Follow.follower_id == viewer_id,
            Follow.followee_id.in_(target_ids),
        )
    )
    return {r for (r,) in rows.all()}


async def _blocked_by_viewer_set(
    db: AsyncSession, viewer_id: UUID, target_ids: list[UUID]
) -> set[UUID]:
    """Return the subset of `target_ids` that `viewer_id` has blocked."""
    if not target_ids:
        return set()
    rows = await db.execute(
        select(Block.blockee_id).where(
            Block.blocker_id == viewer_id,
            Block.blockee_id.in_(target_ids),
        )
    )
    return {r for (r,) in rows.all()}


async def _viewer_invisible_to(db: AsyncSession, viewer_id: UUID) -> set[UUID]:
    """User ids whose content `viewer_id` should not see.

    Either side of a block hides the other: if A blocked viewer or
    viewer blocked A, A goes in the set. Used to filter search results,
    follower / following lists, and the public profile fetch so blocks
    are bidirectional in practice.
    """
    rows = await db.execute(
        select(Block.blocker_id, Block.blockee_id).where(
            (Block.blocker_id == viewer_id) | (Block.blockee_id == viewer_id)
        )
    )
    out: set[UUID] = set()
    for blocker, blockee in rows.all():
        out.add(blockee if blocker == viewer_id else blocker)
    return out


@router.get("/{user_id}", response_model=PublicUser)
async def get_public_user(
    user_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Public profile view — the slim, non-sensitive subset of the user
    record, used by the in-app author profile page."""
    posts_count = (
        select(func.count(FeedItem.id))
        .where(FeedItem.author_id == user_id)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .scalar_subquery()
    )
    followers_count = (
        select(func.count(Follow.id))
        .where(Follow.followee_id == user_id)
        .scalar_subquery()
    )
    following_count = (
        select(func.count(Follow.id))
        .where(Follow.follower_id == user_id)
        .scalar_subquery()
    )
    stmt = (
        select(
            User,
            posts_count.label("posts_count"),
            followers_count.label("followers_count"),
            following_count.label("following_count"),
        )
        .where(User.id == user_id)
    )
    row = (await db.execute(stmt)).first()
    if not row:
        raise HTTPException(status_code=404, detail="User not found")
    u, p, fc, gc = row
    is_following = False
    is_blocked = False
    if user.id != user_id:
        # If the *target* has blocked the viewer, hide the profile entirely
        # so block is not detectable. Viewer-blocked-target still resolves
        # because the viewer needs a way to unblock from the profile.
        target_blocks_viewer = (
            await db.execute(
                select(Block.id).where(
                    Block.blocker_id == user_id,
                    Block.blockee_id == user.id,
                )
            )
        ).first() is not None
        if target_blocks_viewer:
            raise HTTPException(status_code=404, detail="User not found")
        is_following = (
            await db.execute(
                select(Follow.id).where(
                    Follow.follower_id == user.id,
                    Follow.followee_id == user_id,
                )
            )
        ).first() is not None
        is_blocked = (
            await db.execute(
                select(Block.id).where(
                    Block.blocker_id == user.id,
                    Block.blockee_id == user_id,
                )
            )
        ).first() is not None
    return PublicUser(
        id=u.id,
        name=u.name,
        photo_url=u.photo_url,
        photo_meta=u.photo_meta,
        posts_count=int(p or 0),
        followers_count=int(fc or 0),
        following_count=int(gc or 0),
        is_following=is_following,
        is_blocked=is_blocked,
    )


@router.post("/{user_id}/follow")
async def follow_user(
    user_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Follow another user. Idempotent — re-follow is a no-op.

    Self-follow is rejected at the DB layer (CHECK constraint) and here
    so we can return a clean 400 instead of a 500.
    """
    if user_id == user.id:
        raise HTTPException(status_code=400, detail="Cannot follow yourself")
    target = (
        await db.execute(select(User).where(User.id == user_id))
    ).scalar_one_or_none()
    if target is None:
        raise HTTPException(status_code=404, detail="User not found")

    # Either side of a block stops a follow. Returns 404 (not 403) so we
    # don't leak which user is doing the blocking.
    block_exists = (
        await db.execute(
            select(Block.id).where(
                ((Block.blocker_id == user.id) & (Block.blockee_id == user_id))
                | ((Block.blocker_id == user_id) & (Block.blockee_id == user.id))
            )
        )
    ).first()
    if block_exists is not None:
        raise HTTPException(status_code=404, detail="User not found")

    existing = (
        await db.execute(
            select(Follow.id).where(
                Follow.follower_id == user.id,
                Follow.followee_id == user_id,
            )
        )
    ).first()
    if existing is None:
        db.add(Follow(follower_id=user.id, followee_id=user_id))
        try:
            await db.flush()
        except IntegrityError:
            # Race with a concurrent follow — treat as already-followed.
            await db.rollback()
        else:
            await create_notification(
                db,
                recipient_id=user_id,
                kind="follow",
                actor=user,
            )
            await db.commit()

    followers_count = (
        await db.execute(
            select(func.count(Follow.id)).where(Follow.followee_id == user_id)
        )
    ).scalar_one()
    return {
        "ok": True,
        "is_following": True,
        "followers_count": int(followers_count or 0),
    }


@router.delete("/{user_id}/follow")
async def unfollow_user(
    user_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Unfollow. Idempotent — no error if not currently following."""
    follow = (
        await db.execute(
            select(Follow).where(
                Follow.follower_id == user.id,
                Follow.followee_id == user_id,
            )
        )
    ).scalar_one_or_none()
    if follow is not None:
        await db.delete(follow)
        await db.commit()

    followers_count = (
        await db.execute(
            select(func.count(Follow.id)).where(Follow.followee_id == user_id)
        )
    ).scalar_one()
    return {
        "ok": True,
        "is_following": False,
        "followers_count": int(followers_count or 0),
    }


@router.get("/{user_id}/followers", response_model=list[PublicUser])
async def list_followers(
    user_id: UUID,
    limit: int = Query(50, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    return await _list_relations(db, viewer_id=user.id, target_id=user_id, limit=limit, mode="followers")


@router.get("/{user_id}/following", response_model=list[PublicUser])
async def list_following(
    user_id: UUID,
    limit: int = Query(50, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    return await _list_relations(db, viewer_id=user.id, target_id=user_id, limit=limit, mode="following")


@router.delete("/{user_id}/follower")
async def remove_follower(
    user_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Drop `user_id`'s follow of the current user. Idempotent.

    This is the inverse of `unfollow_user`: there the caller stops
    following someone; here the caller removes someone who follows
    them, without escalating to a block. Used by the "Remove" action on
    the Followers list of the user's own profile.
    """
    if user_id == user.id:
        raise HTTPException(status_code=400, detail="Cannot remove yourself")
    follow = (
        await db.execute(
            select(Follow).where(
                Follow.follower_id == user_id,
                Follow.followee_id == user.id,
            )
        )
    ).scalar_one_or_none()
    if follow is not None:
        await db.delete(follow)
        await db.commit()
    followers_count = (
        await db.execute(
            select(func.count(Follow.id)).where(Follow.followee_id == user.id)
        )
    ).scalar_one()
    return {"ok": True, "followers_count": int(followers_count or 0)}


@router.post("/{user_id}/block")
async def block_user(
    user_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Block `user_id`. Idempotent.

    A new block also tears down any existing follow relationship in
    *either* direction so the block takes effect immediately for both
    parties without an extra round-trip from the client.
    """
    if user_id == user.id:
        raise HTTPException(status_code=400, detail="Cannot block yourself")
    target = (
        await db.execute(select(User).where(User.id == user_id))
    ).scalar_one_or_none()
    if target is None:
        raise HTTPException(status_code=404, detail="User not found")

    existing = (
        await db.execute(
            select(Block.id).where(
                Block.blocker_id == user.id,
                Block.blockee_id == user_id,
            )
        )
    ).first()
    if existing is None:
        db.add(Block(blocker_id=user.id, blockee_id=user_id))
        try:
            await db.flush()
        except IntegrityError:
            await db.rollback()

    # Drop follows in both directions so counts settle immediately.
    await db.execute(
        Follow.__table__.delete().where(
            ((Follow.follower_id == user.id) & (Follow.followee_id == user_id))
            | ((Follow.follower_id == user_id) & (Follow.followee_id == user.id))
        )
    )
    await db.commit()
    return {"ok": True, "is_blocked": True}


@router.delete("/{user_id}/block")
async def unblock_user(
    user_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Unblock. Idempotent — no error if not currently blocked."""
    block = (
        await db.execute(
            select(Block).where(
                Block.blocker_id == user.id,
                Block.blockee_id == user_id,
            )
        )
    ).scalar_one_or_none()
    if block is not None:
        await db.delete(block)
        await db.commit()
    return {"ok": True, "is_blocked": False}


@router.get("/me/blocked", response_model=list[PublicUser])
async def list_blocked(
    limit: int = Query(100, ge=1, le=200),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Users the current viewer has blocked, newest first."""
    posts_count = (
        select(func.count(FeedItem.id))
        .where(FeedItem.author_id == User.id)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .correlate(User)
        .scalar_subquery()
    )
    followers_count = _follower_count_subquery(User.id)
    following_count = _following_count_subquery(User.id)
    stmt = (
        select(
            User,
            posts_count.label("posts_count"),
            followers_count.label("followers_count"),
            following_count.label("following_count"),
            Block.created_at,
        )
        .join(Block, Block.blockee_id == User.id)
        .where(Block.blocker_id == user.id)
        .order_by(Block.created_at.desc())
        .limit(limit)
    )
    rows = (await db.execute(stmt)).all()
    return [
        PublicUser(
            id=u.id,
            name=u.name,
            photo_url=u.photo_url,
            photo_meta=u.photo_meta,
            posts_count=int(p or 0),
            followers_count=int(fc or 0),
            following_count=int(gc or 0),
            is_following=False,
            is_blocked=True,
        )
        for u, p, fc, gc, _ in rows
    ]


async def _list_relations(
    db: AsyncSession,
    *,
    viewer_id: UUID,
    target_id: UUID,
    limit: int,
    mode: str,
) -> list[PublicUser]:
    """Resolve followers/following list for `target_id`.

    `mode` selects which side of the join we walk: "followers" returns
    users who follow target; "following" returns users target follows.
    Each row carries the same enriched counts as a search hit so the
    list rows can render exactly like search results.
    """
    if mode == "followers":
        join_cond = Follow.follower_id == User.id
        target_filter = Follow.followee_id == target_id
    else:
        join_cond = Follow.followee_id == User.id
        target_filter = Follow.follower_id == target_id

    posts_count = (
        select(func.count(FeedItem.id))
        .where(FeedItem.author_id == User.id)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .correlate(User)
        .scalar_subquery()
    )
    followers_count = _follower_count_subquery(User.id)
    following_count = _following_count_subquery(User.id)
    invisible = await _viewer_invisible_to(db, viewer_id)
    stmt = (
        select(
            User,
            posts_count.label("posts_count"),
            followers_count.label("followers_count"),
            following_count.label("following_count"),
            Follow.created_at,
        )
        .join(Follow, join_cond)
        .where(target_filter)
        .order_by(Follow.created_at.desc())
        .limit(limit)
    )
    if invisible:
        stmt = stmt.where(User.id.notin_(invisible))
    rows = (await db.execute(stmt)).all()
    target_ids = [u.id for u, *_ in rows]
    following_set = await _following_set(db, viewer_id, target_ids)
    blocked_set = await _blocked_by_viewer_set(db, viewer_id, target_ids)
    return [
        PublicUser(
            id=u.id,
            name=u.name,
            photo_url=u.photo_url,
            photo_meta=u.photo_meta,
            posts_count=int(p or 0),
            followers_count=int(fc or 0),
            following_count=int(gc or 0),
            is_following=u.id in following_set,
            is_blocked=u.id in blocked_set,
        )
        for u, p, fc, gc, _ in rows
    ]


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
    # Any change to a recommendation-relevant list (likes, saved_posts,
    # favorite_posts, reading_list) invalidates the cached profile.
    if field in {"likes", "saved_posts", "favorite_posts", "reading_list"}:
        from app.ai.recommendation import invalidate_user_profile_cache
        invalidate_user_profile_cache(user.id)
    return {"ok": True, field: current}
