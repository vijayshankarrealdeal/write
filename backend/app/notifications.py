"""Helpers for creating + delivering in-app notifications.

Centralizing this keeps the routers thin and means new notification
kinds get a single place to extend (e.g. add a 'follow' kind without
touching every route that triggers one).
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.logger import get_logger
from app.models.feed_item import FeedItem
from app.models.notification import Notification
from app.models.user import User
from app.push_dispatcher import dispatch_push, push_enabled
from app.realtime import hub

log = get_logger("app.notifications")


async def create_notification(
    db: AsyncSession,
    *,
    recipient_id: UUID,
    kind: str,
    actor: User | None,
    feed_item: FeedItem | None = None,
    data: dict[str, Any] | None = None,
) -> Notification | None:
    """Persist a notification and push it over the user's WebSocket.

    Returns ``None`` if recipient == actor (no self-notifications), which
    keeps the call-sites short — they don't need to filter.
    """
    if actor is not None and actor.id == recipient_id:
        return None

    notif = Notification(
        user_id=recipient_id,
        kind=kind,
        actor_id=actor.id if actor else None,
        actor_name=actor.name if actor else None,
        actor_photo_url=actor.photo_url if actor else None,
        feed_item_id=feed_item.id if feed_item else None,
        feed_item_title=feed_item.title if feed_item else None,
        data=data,
    )
    db.add(notif)
    # Caller commits as part of its own transaction so we don't double-flush.
    await db.flush()

    payload = {
        "type": "notification",
        "id": str(notif.id),
        "kind": notif.kind,
        "actor_id": str(notif.actor_id) if notif.actor_id else None,
        "actor_name": notif.actor_name,
        "actor_photo_url": notif.actor_photo_url,
        "feed_item_id": str(notif.feed_item_id) if notif.feed_item_id else None,
        "feed_item_title": notif.feed_item_title,
        "data": notif.data,
        "read": notif.read,
        "created_at": notif.created_at.isoformat() if notif.created_at else None,
    }
    try:
        await hub.send_to_user(recipient_id, payload)
    except Exception as exc:  # don't let realtime hiccups break the route
        log.warning("notification SSE dispatch failed: %s", exc)

    # OS-level push (FCM / APNS) — best-effort; no-op when not configured.
    if push_enabled():
        try:
            title = _push_title(notif)
            body = _push_body(notif)
            await dispatch_push(
                db,
                user_id=recipient_id,
                title=title,
                body=body,
                data={
                    "notification_id": str(notif.id),
                    "kind": notif.kind,
                    "feed_item_id": str(notif.feed_item_id)
                    if notif.feed_item_id
                    else "",
                },
            )
        except Exception as exc:
            log.warning("push dispatch failed: %s", exc)

    return notif


def _push_title(notif: Notification) -> str:
    actor = notif.actor_name or "Someone"
    if notif.kind == "like":
        return f"{actor} liked your story"
    if notif.kind == "comment":
        return f"{actor} commented on your story"
    if notif.kind == "reply":
        return f"{actor} replied to your comment"
    if notif.kind == "follow":
        return f"{actor} started following you"
    return "InkSpaceX"


def _push_body(notif: Notification) -> str:
    excerpt = (notif.data or {}).get("excerpt") if notif.data else None
    if isinstance(excerpt, str) and excerpt:
        return excerpt
    return notif.feed_item_title or ""
