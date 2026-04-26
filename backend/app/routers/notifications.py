"""REST API for the in-app notification center.

Pairs with ``app.routers.realtime`` for live delivery — the WebSocket
pushes new notifications as they're created, this router lets the
client load history, count unread, and mark them read.
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Query
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.notification import Notification
from app.models.user import User
from app.schemas.notification import (
    MarkReadRequest,
    NotificationResponse,
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
