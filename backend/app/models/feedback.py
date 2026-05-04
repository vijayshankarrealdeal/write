"""User-submitted feedback about the app — distinct from `reports`.

`reports` is for moderation of UGC (a story / comment / user). `feedback`
is for product input: bugs, feature requests, general impressions. Lives
in its own table so the admin queue stays focused on moderation and
doesn't get drowned by feature requests.
"""
import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, String, Text, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDMixin


# Plain tuples (not Enums) so adding a category / status doesn't require
# a migration — same convention as `app.models.report`.
FEEDBACK_CATEGORIES = ("bug", "feature", "praise", "other")
FEEDBACK_STATUSES = ("new", "seen", "resolved")


class Feedback(UUIDMixin, Base):
    __tablename__ = "feedbacks"

    user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    category: Mapped[str] = mapped_column(String(16), nullable=False, default="other")
    message: Mapped[str] = mapped_column(Text, nullable=False)
    platform: Mapped[str | None] = mapped_column(String(16))
    app_version: Mapped[str | None] = mapped_column(String(32))

    status: Mapped[str] = mapped_column(
        String(16), nullable=False, default="new"
    )
    resolver_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), index=True
    )

    __table_args__ = (
        Index("ix_feedbacks_status_created", "status", "created_at"),
    )
