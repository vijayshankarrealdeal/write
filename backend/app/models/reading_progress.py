import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, Float, ForeignKey, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import UUID
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

    # Relationships
    user: Mapped["User"] = relationship(back_populates="reading_progress")  # noqa: F821

    __table_args__ = (
        UniqueConstraint("user_id", "feed_item_id", name="uq_user_feed_item"),
    )
