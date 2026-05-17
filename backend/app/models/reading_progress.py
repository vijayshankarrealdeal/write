import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Index,
    String,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UUIDMixin


class ReadingProgress(UUIDMixin, Base):
    __tablename__ = "reading_progress"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    feed_item_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("feed_items.id", ondelete="CASCADE"), nullable=False
    )
    scroll_position: Mapped[float | None] = mapped_column(Float)
    last_read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    completed: Mapped[bool] = mapped_column(Boolean, default=False)
    # Set the first time ``completed`` flips false → true. Drives the
    # Library "Finished" tab ordering and lets the UI say "you finished
    # this on May 14" without reaching for last_read_at as a proxy.
    # Nullable because pre-migration rows lacked it; backfilled with
    # last_read_at by 20260517_01.
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Paragraph-precise resume anchor — the section the user was last in
    # plus the in-section anchor. Both nullable so existing rows don't
    # need a backfill; the client falls back to scroll_position when
    # last_anchor is missing.
    last_section_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # {"paragraph_idx": int, "char_offset": int}
    last_anchor: Mapped[dict | None] = mapped_column(JSONB, nullable=True)

    # Relationships
    user: Mapped["User"] = relationship(back_populates="reading_progress")  # noqa: F821

    __table_args__ = (
        UniqueConstraint("user_id", "feed_item_id", name="uq_user_feed_item"),
        # "Continue reading" rail — newest first per user, cap 8.
        Index("ix_reading_progress_user_last_read", "user_id", "last_read_at"),
        # Library "Finished" tab — newest-finished first per user.
        Index("ix_reading_progress_user_finished", "user_id", "finished_at"),
    )
