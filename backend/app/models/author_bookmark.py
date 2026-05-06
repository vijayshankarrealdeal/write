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
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UUIDMixin


class AuthorBookmark(UUIDMixin, Base):
    """Writer-side flag-this-spot mark inside a draft section.

    Distinct from ``Bookmark`` (reader-side, anchored to a feed item +
    paragraph_idx). Author bookmarks live on a draft ``Section`` and
    record a single character offset into the section's plain-text view.
    Offsets travel with the document — the client adjusts each marker
    when text is inserted/deleted before it via Quill delta math, then
    syncs the new offset through the outbox.
    """

    __tablename__ = "author_bookmarks"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    writing_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("writings.id", ondelete="CASCADE"),
        nullable=False,
    )
    # Section ids are UUID-shaped at rest but kept as String here to mirror
    # the rest of the section-anchored tables (`bookmarks.section_id`,
    # `reading_progress.last_section_id`) and avoid coupling to the section
    # PK type — the section may be created locally with a non-UUID id and
    # remapped after the first sync.
    section_id: Mapped[str] = mapped_column(String(64), nullable=False)
    offset: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    label: Mapped[str | None] = mapped_column(String(120), nullable=True)
    color: Mapped[str] = mapped_column(String(10), nullable=False, default="#FFB300")

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    user: Mapped["User"] = relationship(back_populates="author_bookmarks")  # noqa: F821

    __table_args__ = (
        # The "show all my marks for this section" path is the most common
        # query (Inspector tab). (user_id, section_id) covers it tightly.
        Index("ix_author_bookmarks_user_section", "user_id", "section_id"),
        # Project-wide list groups by writing.
        Index("ix_author_bookmarks_user_writing", "user_id", "writing_id"),
        # Outbox replays should not duplicate. The natural key is
        # (user, section, offset) — two marks at the same offset round-trip
        # to a single row.
        UniqueConstraint(
            "user_id",
            "section_id",
            "offset",
            name="uq_author_bookmark_offset",
        ),
    )
