import uuid
from datetime import datetime

from sqlalchemy import (
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UUIDMixin


class Bookmark(UUIDMixin, Base):
    """A named in-text bookmark.

    Anchor is paragraph + char offset rather than a raw scroll position so
    a bookmark survives reflow across devices and font-size changes. The
    section can be tagged either by stable id (when the section_index is
    not enough — e.g. sections reordered post-publish) or by index;
    section_id is preferred when known.
    """

    __tablename__ = "bookmarks"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    feed_item_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("feed_items.id", ondelete="CASCADE"),
        nullable=False,
    )
    section_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    section_index: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    # {"paragraph_idx": int, "char_offset": int}
    anchor: Mapped[dict] = mapped_column(JSONB, nullable=False)
    label: Mapped[str | None] = mapped_column(String(120), nullable=True)
    color: Mapped[str] = mapped_column(String(10), nullable=False, default="#FFB300")

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    user: Mapped["User"] = relationship(back_populates="bookmarks")  # noqa: F821

    __table_args__ = (
        # The "show all my marks on this writing" path is the most common
        # query; (user_id, feed_item_id) covers it with no extra work.
        Index("ix_bookmarks_user_feed_item", "user_id", "feed_item_id"),
        Index("ix_bookmarks_user_updated", "user_id", "updated_at"),
        # A user shouldn't end up with two duplicate marks at the exact same
        # spot from a double-tap. Anchor is JSONB so we can't put it in a
        # normal unique index — enforce dedupe at the application layer
        # (see routers/bookmarks.py upsert path) and constrain only the
        # (user, item, section_index) trio that the UI exposes.
        UniqueConstraint(
            "user_id",
            "feed_item_id",
            "section_index",
            "anchor",
            name="uq_bookmark_anchor",
        ),
    )
