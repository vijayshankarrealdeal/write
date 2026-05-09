from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.exc import IntegrityError

from app.auth.deps import get_current_user
from app.badges import Badge, compute_reader_tier, compute_writer_tier
from app.database import get_db
from app.models.block import Block
from app.models.comment import Comment
from app.models.feed_item import FeedItem
from app.models.follow import Follow
from app.models.highlight import Highlight
from app.models.reading_progress import ReadingProgress
from app.models.user import User
from app.notifications import create_notification
from app.schemas.user import (
    ListUpdateRequest,
    UserResponse,
    UserUpdate,
    normalize_bio,
    normalize_social_links,
)

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
    # Author bio + social handles are part of the public profile —
    # surfaced on `/u/:id` so other users can place the author and
    # follow them off-platform. Both fields are optional and may be
    # null for users who haven't filled them in yet.
    bio: str | None = None
    social_links: dict | None = None
    posts_count: int = 0
    followers_count: int = 0
    following_count: int = 0
    is_following: bool = False
    # Viewer has sent a follow request that the target hasn't yet
    # approved. Mutually exclusive with `is_following`. The Flutter
    # UI uses this to render the 'Requested' state.
    follow_request_pending: bool = False
    # True if the target has any private writings — i.e. following
    # them requires approval. Lets the client show the right CTA
    # ('Request to follow' vs 'Follow') ahead of the round-trip.
    requires_follow_approval: bool = False
    is_blocked: bool = False
    # Tier badges. `writer_badge` is computed cheaply from counts that
    # are already in the response (posts_count, followers_count, plus a
    # likes_received subquery added below). `reader_badge` is only
    # populated on the single-user fetch (`/users/{id}`) — it requires
    # joining reading_progress and highlights, which we don't pay for
    # on every search/list row.
    writer_badge: Badge | None = None
    reader_badge: Badge | None = None

    model_config = {"from_attributes": True}


def _likes_received_subquery(target_col):
    """Sum of likes_count across the user's published feed items.

    Drives the writer-tier badge — gating on *received* engagement
    rather than raw publish count is what stops the badge system from
    rewarding spam.
    """
    return (
        select(func.coalesce(func.sum(FeedItem.likes_count), 0))
        .where(FeedItem.author_id == target_col)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .correlate(User)
        .scalar_subquery()
    )


def _comments_received_subquery(target_col):
    """Sum of comments_count across the user's published feed items.

    Comments are higher-friction than likes (they require typing a
    sentence, not a tap), so they're a better signal of resonance and
    much harder to farm. Used as a co-requirement at every non-trivial
    writer tier.
    """
    return (
        select(func.coalesce(func.sum(FeedItem.comments_count), 0))
        .where(FeedItem.author_id == target_col)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .correlate(User)
        .scalar_subquery()
    )


def _follower_count_subquery(target_col):
    """Count of approved followers only — pending requests don't count
    toward the public follower number on the profile card."""
    return (
        select(func.count(Follow.id))
        .where(Follow.followee_id == target_col)
        .where(Follow.status == "approved")
        .correlate(User)
        .scalar_subquery()
    )


def _following_count_subquery(target_col):
    """Count of approved 'following' rows only — sent-but-pending requests
    don't surface as 'following' until the target approves."""
    return (
        select(func.count(Follow.id))
        .where(Follow.follower_id == target_col)
        .where(Follow.status == "approved")
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
    likes_received = _likes_received_subquery(User.id)
    comments_received = _comments_received_subquery(User.id)
    invisible = await _viewer_invisible_to(db, user.id)
    stmt = (
        select(
            User,
            posts_count.label("posts_count"),
            followers_count.label("followers_count"),
            following_count.label("following_count"),
            likes_received.label("likes_received"),
            comments_received.label("comments_received"),
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
    pending_set = await _pending_request_set(db, user.id, target_ids)
    # Compute requires_follow_approval per-row in a single pass: a user is
    # gated if they have any published private writing.
    if target_ids:
        gated_rows = await db.execute(
            select(FeedItem.author_id)
            .where(FeedItem.author_id.in_(target_ids))
            .where(FeedItem.is_draft == False)  # noqa: E712
            .where(FeedItem.visibility == "private")
            .distinct()
        )
        gated_set: set[UUID] = {r for (r,) in gated_rows.all()}
    else:
        gated_set = set()
    return [
        PublicUser(
            id=u.id,
            name=u.name,
            photo_url=u.photo_url,
            photo_meta=u.photo_meta,
            bio=u.bio,
            social_links=u.social_links,
            posts_count=int(p or 0),
            followers_count=int(fc or 0),
            following_count=int(gc or 0),
            is_following=u.id in following_set,
            follow_request_pending=u.id in pending_set,
            requires_follow_approval=u.id in gated_set,
            writer_badge=compute_writer_tier(
                published=int(p or 0),
                likes_received=int(lr or 0),
                followers=int(fc or 0),
                comments_received=int(cr or 0),
                email=u.email,
            ),
        )
        for u, p, fc, gc, lr, cr in rows
    ]


async def _following_set(
    db: AsyncSession, viewer_id: UUID, target_ids: list[UUID]
) -> set[UUID]:
    """Return the subset of `target_ids` that `viewer_id` follows
    (approved only — pending requests are reported separately via
    `_pending_request_set`).

    One round-trip instead of N — keeps search results O(1) DB hits.
    """
    if not target_ids:
        return set()
    rows = await db.execute(
        select(Follow.followee_id).where(
            Follow.follower_id == viewer_id,
            Follow.followee_id.in_(target_ids),
            Follow.status == "approved",
        )
    )
    return {r for (r,) in rows.all()}


async def _pending_request_set(
    db: AsyncSession, viewer_id: UUID, target_ids: list[UUID]
) -> set[UUID]:
    """Return the subset of `target_ids` for which `viewer_id` has a
    pending follow request awaiting approval. Used to render the
    'Requested' state in the profile / search UI."""
    if not target_ids:
        return set()
    rows = await db.execute(
        select(Follow.followee_id).where(
            Follow.follower_id == viewer_id,
            Follow.followee_id.in_(target_ids),
            Follow.status == "pending",
        )
    )
    return {r for (r,) in rows.all()}


async def _has_private_writings(db: AsyncSession, target_id: UUID) -> bool:
    """True if `target_id` has any published `visibility='private'` items.
    Drives the decision at follow-request time: target with no private
    content auto-approves, target with private content requires approval."""
    row = await db.execute(
        select(FeedItem.id)
        .where(FeedItem.author_id == target_id)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .where(FeedItem.visibility == "private")
        .limit(1)
    )
    return row.scalar_one_or_none() is not None


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
        .where(Follow.status == "approved")
        .scalar_subquery()
    )
    following_count = (
        select(func.count(Follow.id))
        .where(Follow.follower_id == user_id)
        .where(Follow.status == "approved")
        .scalar_subquery()
    )
    likes_received = (
        select(func.coalesce(func.sum(FeedItem.likes_count), 0))
        .where(FeedItem.author_id == user_id)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .scalar_subquery()
    )
    comments_received = (
        select(func.coalesce(func.sum(FeedItem.comments_count), 0))
        .where(FeedItem.author_id == user_id)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .scalar_subquery()
    )
    # Reader-tier inputs. Self-only: completed reads + highlights are
    # personal data — we don't expose them on other users' profiles, so
    # the reader badge is computed but never attached for non-self.
    reads_completed = (
        select(func.count(ReadingProgress.id))
        .where(ReadingProgress.user_id == user_id)
        .where(ReadingProgress.completed == True)  # noqa: E712
        .scalar_subquery()
    )
    highlights_count = (
        select(func.count(Highlight.id))
        .where(Highlight.user_id == user_id)
        .scalar_subquery()
    )
    comments_authored = (
        select(func.count(Comment.id))
        .where(Comment.author_id == user_id)
        .scalar_subquery()
    )
    # Distinct calendar days the user touched a `reading_progress` row.
    # Cheap proxy for "consistency over time" without needing a separate
    # streak table — Postgres treats `DATE(timestamp)` distinctly so the
    # count goes up only once per day no matter how many rows update.
    active_reading_days = (
        select(func.count(func.distinct(func.date(ReadingProgress.last_read_at))))
        .where(ReadingProgress.user_id == user_id)
        .where(ReadingProgress.last_read_at.is_not(None))
        .scalar_subquery()
    )
    stmt = (
        select(
            User,
            posts_count.label("posts_count"),
            followers_count.label("followers_count"),
            following_count.label("following_count"),
            likes_received.label("likes_received"),
            comments_received.label("comments_received"),
            reads_completed.label("reads_completed"),
            highlights_count.label("highlights_count"),
            comments_authored.label("comments_authored"),
            active_reading_days.label("active_reading_days"),
        )
        .where(User.id == user_id)
    )
    row = (await db.execute(stmt)).first()
    if not row:
        raise HTTPException(status_code=404, detail="User not found")
    u, p, fc, gc, lr, cr, rc, hc, ca, ard = row
    is_following = False
    follow_request_pending = False
    is_blocked = False
    requires_follow_approval = False
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
        # Resolve viewer's relationship to target in one round-trip:
        # is_following / requested / blocked / approval-required.
        follow_row = (
            await db.execute(
                select(Follow.status).where(
                    Follow.follower_id == user.id,
                    Follow.followee_id == user_id,
                )
            )
        ).scalar_one_or_none()
        if follow_row == "approved":
            is_following = True
        elif follow_row == "pending":
            follow_request_pending = True
        is_blocked = (
            await db.execute(
                select(Block.id).where(
                    Block.blocker_id == user.id,
                    Block.blockee_id == user_id,
                )
            )
        ).first() is not None
        requires_follow_approval = await _has_private_writings(db, user_id)
    writer_badge = compute_writer_tier(
        published=int(p or 0),
        likes_received=int(lr or 0),
        followers=int(fc or 0),
        comments_received=int(cr or 0),
        email=u.email,
    )
    # Only attach the reader badge on the user's own profile fetch — it's
    # derived from private signal (reads, highlights) so we don't surface
    # it on other authors' public cards.
    reader_badge = (
        compute_reader_tier(
            reads_completed=int(rc or 0),
            highlights=int(hc or 0),
            comments_authored=int(ca or 0),
            active_reading_days=int(ard or 0),
            email=u.email,
        )
        if user.id == user_id
        else None
    )
    return PublicUser(
        id=u.id,
        name=u.name,
        photo_url=u.photo_url,
        photo_meta=u.photo_meta,
        bio=u.bio,
        social_links=u.social_links,
        posts_count=int(p or 0),
        followers_count=int(fc or 0),
        following_count=int(gc or 0),
        is_following=is_following,
        follow_request_pending=follow_request_pending,
        requires_follow_approval=requires_follow_approval,
        is_blocked=is_blocked,
        writer_badge=writer_badge,
        reader_badge=reader_badge,
    )


@router.post("/{user_id}/follow")
async def follow_user(
    user_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Follow another user. Idempotent — re-follow is a no-op.

    If the target has any published private writings, the follow is
    created with `status='pending'` and the target gets a follow-request
    notification they can approve from their inbox. Otherwise the row
    is created `status='approved'` immediately, matching the open-follow
    semantics for fully-public authors.

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
            select(Follow).where(
                Follow.follower_id == user.id,
                Follow.followee_id == user_id,
            )
        )
    ).scalar_one_or_none()
    requires_approval = await _has_private_writings(db, user_id)
    new_status = "pending" if requires_approval else "approved"

    if existing is None:
        db.add(
            Follow(
                follower_id=user.id,
                followee_id=user_id,
                status=new_status,
            )
        )
        try:
            await db.flush()
        except IntegrityError:
            # Race with a concurrent follow — treat as already-followed.
            await db.rollback()
            existing = (
                await db.execute(
                    select(Follow).where(
                        Follow.follower_id == user.id,
                        Follow.followee_id == user_id,
                    )
                )
            ).scalar_one_or_none()
        else:
            # Notification kind differentiates the inbox UX: 'follow' is a
            # confirmed new follower, 'follow_request' is an actionable
            # approve/reject card.
            await create_notification(
                db,
                recipient_id=user_id,
                kind="follow_request" if new_status == "pending" else "follow",
                actor=user,
            )
            await db.commit()

    # Existing row: don't downgrade an approved follow to pending if the
    # target later turned on private writings — they keep their access.
    final_status = existing.status if existing is not None else new_status

    followers_count = (
        await db.execute(
            select(func.count(Follow.id))
            .where(Follow.followee_id == user_id)
            .where(Follow.status == "approved")
        )
    ).scalar_one()
    return {
        "ok": True,
        "is_following": final_status == "approved",
        "follow_request_pending": final_status == "pending",
        "followers_count": int(followers_count or 0),
    }


@router.delete("/{user_id}/follow")
async def unfollow_user(
    user_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Unfollow. Idempotent — no error if not currently following.
    Also cancels a pending follow request, since the same row is dropped
    regardless of status."""
    follow = (
        await db.execute(
            select(Follow).where(
                Follow.follower_id == user.id,
                Follow.followee_id == user_id,
            )
        )
    ).scalar_one_or_none()
    was_approved = follow is not None and follow.status == "approved"
    if follow is not None:
        await db.delete(follow)
        await db.commit()
        if was_approved:
            # Losing access to a previously-followed author's content
            # means the recommender's cached profile is now stale (it
            # may have been showing the author's private items).
            from app.ai.recommendation import invalidate_user_profile_cache
            invalidate_user_profile_cache(user.id)

    followers_count = (
        await db.execute(
            select(func.count(Follow.id))
            .where(Follow.followee_id == user_id)
            .where(Follow.status == "approved")
        )
    ).scalar_one()
    return {
        "ok": True,
        "is_following": False,
        "follow_request_pending": False,
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
            select(func.count(Follow.id))
            .where(Follow.followee_id == user.id)
            .where(Follow.status == "approved")
        )
    ).scalar_one()
    return {"ok": True, "followers_count": int(followers_count or 0)}


# ===== Follow request inbox (Instagram-style approval) ======================
#
# When a user has any published `visibility='private'` writings, follow
# requests against them land here as `Follow` rows with status='pending'.
# The author approves to grant the follower access, or rejects to delete
# the row (the requester sees this as no follow / can re-request later).


class FollowRequestEntry(BaseModel):
    """One pending follow request, enriched with the requester's public
    profile so the inbox card can render without an extra round-trip."""

    follow_id: UUID
    requester: PublicUser
    created_at: str | None


@router.get("/me/follow-requests", response_model=list[FollowRequestEntry])
async def list_follow_requests(
    limit: int = Query(50, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Pending follow requests directed at the current user, newest first.

    Walks the partial index `ix_follows_pending_inbox` so the query
    stays cheap even when the user has tens of thousands of approved
    followers — we only scan the pending slice.
    """
    posts_count = (
        select(func.count(FeedItem.id))
        .where(FeedItem.author_id == User.id)
        .where(FeedItem.is_draft == False)  # noqa: E712
        .correlate(User)
        .scalar_subquery()
    )
    followers_count = _follower_count_subquery(User.id)
    following_count = _following_count_subquery(User.id)
    likes_received = _likes_received_subquery(User.id)
    comments_received = _comments_received_subquery(User.id)
    invisible = await _viewer_invisible_to(db, user.id)
    stmt = (
        select(
            Follow.id,
            Follow.created_at,
            User,
            posts_count.label("posts_count"),
            followers_count.label("followers_count"),
            following_count.label("following_count"),
            likes_received.label("likes_received"),
            comments_received.label("comments_received"),
        )
        .join(User, User.id == Follow.follower_id)
        .where(Follow.followee_id == user.id)
        .where(Follow.status == "pending")
        .order_by(Follow.created_at.desc())
        .limit(limit)
    )
    if invisible:
        stmt = stmt.where(User.id.notin_(invisible))
    rows = (await db.execute(stmt)).all()
    return [
        FollowRequestEntry(
            follow_id=fid,
            created_at=created_at.isoformat() if created_at else None,
            requester=PublicUser(
                id=u.id,
                name=u.name,
                photo_url=u.photo_url,
                photo_meta=u.photo_meta,
                bio=u.bio,
                social_links=u.social_links,
                posts_count=int(p or 0),
                followers_count=int(fc or 0),
                following_count=int(gc or 0),
                writer_badge=compute_writer_tier(
                    published=int(p or 0),
                    likes_received=int(lr or 0),
                    followers=int(fc or 0),
                    comments_received=int(cr or 0),
                    email=u.email,
                ),
            ),
        )
        for fid, created_at, u, p, fc, gc, lr, cr in rows
    ]


@router.post("/me/follow-requests/{follow_id}/approve")
async def approve_follow_request(
    follow_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Approve a pending follow request. Flips status to 'approved' and
    notifies the requester so they know they now have access."""
    follow = (
        await db.execute(
            select(Follow).where(
                Follow.id == follow_id,
                Follow.followee_id == user.id,
                Follow.status == "pending",
            )
        )
    ).scalar_one_or_none()
    if follow is None:
        raise HTTPException(status_code=404, detail="Follow request not found")
    follow.status = "approved"
    await create_notification(
        db,
        recipient_id=follow.follower_id,
        kind="follow_request_approved",
        actor=user,
    )
    await db.commit()
    # The requester's recommendation profile is now eligible to surface
    # the approver's private content; drop their cached profile so the
    # next /recommendations call re-queries the visibility-gated pool.
    from app.ai.recommendation import invalidate_user_profile_cache
    invalidate_user_profile_cache(follow.follower_id)
    return {"ok": True, "follow_id": str(follow_id), "status": "approved"}


@router.post("/me/follow-requests/{follow_id}/reject", status_code=204)
async def reject_follow_request(
    follow_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Reject a pending follow request. Drops the row entirely so the
    requester is not shown a 'rejected' state — same UX as 'never sent'.
    They can request again, and we don't notify (matches Instagram)."""
    follow = (
        await db.execute(
            select(Follow).where(
                Follow.id == follow_id,
                Follow.followee_id == user.id,
                Follow.status == "pending",
            )
        )
    ).scalar_one_or_none()
    if follow is None:
        raise HTTPException(status_code=404, detail="Follow request not found")
    await db.delete(follow)
    await db.commit()


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
    likes_received = _likes_received_subquery(User.id)
    comments_received = _comments_received_subquery(User.id)
    stmt = (
        select(
            User,
            posts_count.label("posts_count"),
            followers_count.label("followers_count"),
            following_count.label("following_count"),
            likes_received.label("likes_received"),
            comments_received.label("comments_received"),
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
            bio=u.bio,
            social_links=u.social_links,
            posts_count=int(p or 0),
            followers_count=int(fc or 0),
            following_count=int(gc or 0),
            is_following=False,
            is_blocked=True,
            writer_badge=compute_writer_tier(
                published=int(p or 0),
                likes_received=int(lr or 0),
                followers=int(fc or 0),
                comments_received=int(cr or 0),
                email=u.email,
            ),
        )
        for u, p, fc, gc, lr, cr, _ in rows
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
    likes_received = _likes_received_subquery(User.id)
    comments_received = _comments_received_subquery(User.id)
    invisible = await _viewer_invisible_to(db, viewer_id)
    stmt = (
        select(
            User,
            posts_count.label("posts_count"),
            followers_count.label("followers_count"),
            following_count.label("following_count"),
            likes_received.label("likes_received"),
            comments_received.label("comments_received"),
            Follow.created_at,
        )
        .join(Follow, join_cond)
        .where(target_filter)
        # Pending requests don't appear in the public follower/following
        # lists — only the target's own inbox sees them.
        .where(Follow.status == "approved")
        .order_by(Follow.created_at.desc())
        .limit(limit)
    )
    if invisible:
        stmt = stmt.where(User.id.notin_(invisible))
    rows = (await db.execute(stmt)).all()
    target_ids = [u.id for u, *_ in rows]
    following_set = await _following_set(db, viewer_id, target_ids)
    pending_set = await _pending_request_set(db, viewer_id, target_ids)
    blocked_set = await _blocked_by_viewer_set(db, viewer_id, target_ids)
    return [
        PublicUser(
            id=u.id,
            name=u.name,
            photo_url=u.photo_url,
            photo_meta=u.photo_meta,
            bio=u.bio,
            social_links=u.social_links,
            posts_count=int(p or 0),
            followers_count=int(fc or 0),
            following_count=int(gc or 0),
            is_following=u.id in following_set,
            follow_request_pending=u.id in pending_set,
            is_blocked=u.id in blocked_set,
            writer_badge=compute_writer_tier(
                published=int(p or 0),
                likes_received=int(lr or 0),
                followers=int(fc or 0),
                comments_received=int(cr or 0),
                email=u.email,
            ),
        )
        for u, p, fc, gc, lr, cr, _ in rows
    ]


@router.put("/me", response_model=UserResponse)
async def update_profile(
    data: UserUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    payload = data.model_dump(exclude_unset=True)
    # Bio + social_links are user-controlled free-text fields shown to
    # other users — normalize before persisting so we don't store
    # whitespace-only blobs, oversized values, or unknown social keys.
    if "bio" in payload:
        payload["bio"] = normalize_bio(payload["bio"])
    if "social_links" in payload:
        payload["social_links"] = normalize_social_links(payload["social_links"])
    for field, value in payload.items():
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
