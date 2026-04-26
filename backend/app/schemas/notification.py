from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class NotificationResponse(BaseModel):
    id: UUID
    kind: str
    actor_id: UUID | None
    actor_name: str | None
    actor_photo_url: str | None
    feed_item_id: UUID | None
    feed_item_title: str | None
    data: dict | None
    read: bool
    created_at: datetime

    model_config = {"from_attributes": True}


class UnreadCountResponse(BaseModel):
    unread: int


class MarkReadRequest(BaseModel):
    ids: list[UUID] | None = None


class PushSubscriptionCreate(BaseModel):
    platform: str  # 'fcm' | 'apns' | 'web'
    token: str
    device_label: str | None = None


class PushSubscriptionResponse(BaseModel):
    id: UUID
    platform: str
    device_label: str | None
    created_at: datetime
    last_seen_at: datetime

    model_config = {"from_attributes": True}
