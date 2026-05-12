import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, Integer, String, Text, func
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDMixin


class BookCharacter(UUIDMixin, Base):
    """A named figure that recurs across a book's chapters.

    Populated by the ingest pipeline's scout phase (the model reads the
    book and proposes 2-8 characters worth illustrating consistently)
    and the character-sheets phase (each one gets a canonical portrait).
    Surfaced to readers as a "cast" strip on the book detail page;
    tapping a character opens a detail page with the larger portrait
    plus the appearance description.

    `image_url` points at the medium WebP variant for inline rendering;
    `image_meta` carries blurhash + dominant color + the full variant
    table so the client can blur-up and pick the right resolution per
    layout. Both nullable — books without illustration (essays,
    landscape-only) keep a clean schema by not creating rows at all.
    """

    __tablename__ = "book_characters"

    writing_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("writings.id", ondelete="CASCADE"),
        nullable=False,
    )
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    appearance: Mapped[str] = mapped_column(Text, nullable=False)
    # 2-3 sentence "who is this" bio for the character page — role,
    # personality, position in the story, no spoilers. Distinct from
    # `appearance`, which is the scout's image-generation prompt
    # (locks in hair/clothing/build for the art model). Nullable for
    # legacy rows; clients fall back to `appearance` when missing.
    bio: Mapped[str | None] = mapped_column(Text)
    image_url: Mapped[str | None] = mapped_column(Text)
    image_meta: Mapped[dict | None] = mapped_column(JSONB)
    # Preserves the scout's order so the cast strip matches the order
    # the LLM proposed (protagonists first, then supporting figures).
    sort_order: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    __table_args__ = (
        # Cast-strip query — fetch all characters for a writing in
        # sort_order. Covers the common reader path.
        Index("ix_book_characters_writing_sort", "writing_id", "sort_order"),
    )
