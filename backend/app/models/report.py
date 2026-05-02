"""User-generated content reports — Play-policy compliant moderation queue.

Polymorphic by `target_type` so a single table covers stories
(feed_items), comments, users, and chat messages without per-target
shadow tables. `target_id` stays a string to accommodate non-UUID ids
in the future; today every value is a UUID. AI-flagged chat messages
are persisted here too with `reporter_id IS NULL` and `source='ai'`,
so the admin queue is one screen for both user and automated reports.
"""
import uuid
from datetime import datetime

from sqlalchemy import (
    DateTime,
    ForeignKey,
    Index,
    String,
    Text,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDMixin


# Allowed values — kept as plain tuples (not Enum) so adding a new
# target_type / reason / status doesn't require a database migration.
TARGET_TYPES = ("story", "comment", "user", "chat_message")
REPORT_REASONS = (
    "spam",
    "harassment",
    "hate",
    "sexual",
    "violence",
    "self_harm",
    "other",
)
REPORT_STATUSES = ("pending", "actioned", "dismissed")
REPORT_SOURCES = ("user", "ai")


class Report(UUIDMixin, Base):
    __tablename__ = "reports"

    # Null when the report was created by AI moderation (source='ai').
    reporter_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )

    target_type: Mapped[str] = mapped_column(String(24), nullable=False)
    target_id: Mapped[str] = mapped_column(String(64), nullable=False)
    # Snapshot of the reported author at report time so admins can see
    # context even if the target is hard-deleted before review.
    target_author_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )

    reason: Mapped[str] = mapped_column(String(24), nullable=False)
    note: Mapped[str | None] = mapped_column(Text)
    # Snapshot of the reported text/excerpt so the admin queue is useful
    # even after the target is deleted by the user.
    snapshot: Mapped[str | None] = mapped_column(Text)
    # AI moderation metadata (categories, scores, model). User reports
    # leave this null.
    ai_meta: Mapped[dict | None] = mapped_column(JSONB)

    source: Mapped[str] = mapped_column(
        String(8), nullable=False, default="user"
    )
    status: Mapped[str] = mapped_column(
        String(16), nullable=False, default="pending"
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
        Index("ix_reports_status_created", "status", "created_at"),
        Index("ix_reports_target", "target_type", "target_id"),
    )
