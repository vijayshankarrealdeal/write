import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, String, Text, func
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDMixin


class Notification(UUIDMixin, Base):
    __tablename__ = "notifications"

    # Recipient — the user who should see this in their notification center.
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )

    # Notification kind: 'like', 'comment', 'reply', 'system'.
    kind: Mapped[str] = mapped_column(String(32), nullable=False)

    # Optional actor (the user who triggered the notification).
    actor_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL")
    )
    actor_name: Mapped[str | None] = mapped_column(String(255))
    actor_photo_url: Mapped[str | None] = mapped_column(Text)

    # Optional subject — feed_item the notification is about.
    feed_item_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("feed_items.id", ondelete="CASCADE")
    )
    feed_item_title: Mapped[str | None] = mapped_column(String(512))

    # Free-form payload (e.g. comment_id, comment_excerpt). Kept as JSONB so
    # the shape can evolve without migrations.
    data: Mapped[dict | None] = mapped_column(JSONB)

    read: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), index=True
    )
