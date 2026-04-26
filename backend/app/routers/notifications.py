"""REST API for the in-app notification center.

Pairs with ``app.routers.realtime`` for live delivery — the WebSocket
pushes new notifications as they're created, this router lets the
client load history, count unread, and mark them read.
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.notification import Notification
from app.models.push_subscription import PushSubscription
from app.models.user import User
from app.schemas.notification import (
    MarkReadRequest,
    NotificationResponse,
    PushSubscriptionCreate,
    PushSubscriptionResponse,
    UnreadCountResponse,
)

router = APIRouter(prefix="/api/notifications", tags=["notifications"])


@router.get("/", response_model=list[NotificationResponse])
async def list_notifications(
    limit: int = Query(50, le=100),
    cursor: str | None = None,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    query = select(Notification).where(Notification.user_id == user.id)
    if cursor:
        try:
            cursor_uuid = UUID(cursor)
            cursor_row = await db.execute(
                select(Notification).where(Notification.id == cursor_uuid)
            )
            cursor_notification = cursor_row.scalar_one_or_none()
            if cursor_notification:
                query = query.where(
                    Notification.created_at < cursor_notification.created_at
                )
        except ValueError:
            pass
    query = query.order_by(Notification.created_at.desc()).limit(limit)
    result = await db.execute(query)
    return result.scalars().all()


@router.get("/unread-count", response_model=UnreadCountResponse)
async def unread_count(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(func.count(Notification.id)).where(
            Notification.user_id == user.id,
            Notification.read.is_(False),
        )
    )
    return UnreadCountResponse(unread=int(result.scalar() or 0))


@router.post("/mark-read", status_code=204)
async def mark_read(
    data: MarkReadRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    stmt = update(Notification).where(Notification.user_id == user.id)
    if data.ids:
        stmt = stmt.where(Notification.id.in_(data.ids))
    stmt = stmt.values(read=True)
    await db.execute(stmt)
    await db.commit()


@router.delete("/{notification_id}", status_code=204)
async def delete_notification(
    notification_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Notification).where(
            Notification.id == notification_id,
            Notification.user_id == user.id,
        )
    )
    notif = result.scalar_one_or_none()
    if notif:
        await db.delete(notif)
        await db.commit()


# ---------------------------------------------------------------------------
# Push subscription registration
# ---------------------------------------------------------------------------


_VALID_PLATFORMS = {"fcm", "apns", "web"}


@router.post("/push-token", response_model=PushSubscriptionResponse, status_code=201)
async def register_push_token(
    data: PushSubscriptionCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if data.platform not in _VALID_PLATFORMS:
        raise HTTPException(
            status_code=400,
            detail=f"platform must be one of {sorted(_VALID_PLATFORMS)}",
        )
    if not data.token.strip():
        raise HTTPException(status_code=400, detail="token is required")

    # Upsert: same (user_id, token) → bump last_seen_at and update label.
    existing_q = await db.execute(
        select(PushSubscription).where(
            PushSubscription.user_id == user.id,
            PushSubscription.token == data.token,
        )
    )
    sub = existing_q.scalar_one_or_none()
    if sub:
        sub.platform = data.platform
        sub.device_label = data.device_label or sub.device_label
    else:
        sub = PushSubscription(
            user_id=user.id,
            platform=data.platform,
            token=data.token,
            device_label=data.device_label,
        )
        db.add(sub)
    await db.commit()
    await db.refresh(sub)
    return sub


@router.delete("/push-token", status_code=204)
async def unregister_push_token(
    token: str = Query(..., min_length=1),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(PushSubscription).where(
            PushSubscription.user_id == user.id,
            PushSubscription.token == token,
        )
    )
    sub = result.scalar_one_or_none()
    if sub:
        await db.delete(sub)
        await db.commit()
