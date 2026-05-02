from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.comment import Comment
from app.models.feed_item import FeedItem
from app.models.user import User
from app.notifications import create_notification
from app.realtime import hub
from app.schemas.feed import CommentCreate, CommentResponse

router = APIRouter(prefix="/api/feed/{item_id}/comments", tags=["comments"])


def _serialize_comment(comment: Comment) -> dict:
    return {
        "id": str(comment.id),
        "feed_item_id": str(comment.feed_item_id),
        "author_id": str(comment.author_id),
        "author_name": comment.author_name,
        "author_photo_url": comment.author_photo_url,
        "author_photo_meta": comment.author_photo_meta,
        "text": comment.text,
        "rating": comment.rating,
        "created_at": comment.created_at.isoformat() if comment.created_at else None,
    }


@router.get("/", response_model=list[CommentResponse])
async def list_comments(
    item_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    result = await db.execute(
        select(Comment)
        .where(Comment.feed_item_id == item_id)
        .order_by(Comment.created_at.desc())
    )
    return result.scalars().all()


@router.post("/", response_model=CommentResponse, status_code=201)
async def create_comment(
    item_id: UUID,
    data: CommentCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # Verify feed item exists
    result = await db.execute(select(FeedItem).where(FeedItem.id == item_id))
    item = result.scalar_one_or_none()
    if not item:
        raise HTTPException(status_code=404, detail="Feed item not found")

    comment = Comment(
        feed_item_id=item_id,
        author_id=user.id,
        author_name=user.name,
        author_photo_url=user.photo_url,
        author_photo_meta=user.photo_meta,
        text=data.text,
        rating=data.rating,
    )
    db.add(comment)
    item.comments_count = (item.comments_count or 0) + 1
    await db.flush()
    await db.refresh(comment)

    # Notify the author of the post (skip if they're the commenter).
    excerpt = (comment.text or "")[:140]
    await create_notification(
        db,
        recipient_id=item.author_id,
        kind="comment",
        actor=user,
        feed_item=item,
        data={"comment_id": str(comment.id), "excerpt": excerpt},
    )

    await db.commit()

    # Push the new comment to anyone watching this post.
    await hub.broadcast_feed_item(
        item_id,
        {
            "type": "comment.created",
            "comment": _serialize_comment(comment),
            "comments_count": item.comments_count,
        },
    )

    return comment


@router.delete("/{comment_id}", status_code=204)
async def delete_comment(
    item_id: UUID,
    comment_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Comment).where(
            Comment.id == comment_id,
            Comment.feed_item_id == item_id,
            Comment.author_id == user.id,
        )
    )
    comment = result.scalar_one_or_none()
    if not comment:
        raise HTTPException(status_code=404, detail="Comment not found or not yours")

    # Decrement comments count
    item_result = await db.execute(select(FeedItem).where(FeedItem.id == item_id))
    item = item_result.scalar_one_or_none()
    if item:
        item.comments_count = max(0, (item.comments_count or 0) - 1)

    await db.delete(comment)
    await db.commit()

    await hub.broadcast_feed_item(
        item_id,
        {
            "type": "comment.deleted",
            "comment_id": str(comment_id),
            "comments_count": item.comments_count if item else 0,
        },
    )
