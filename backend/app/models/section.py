import uuid
from datetime import datetime

from sqlalchemy import BigInteger, Boolean, DateTime, Float, ForeignKey, Index, Integer, String, func
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UUIDMixin


class Section(UUIDMixin, Base):
    __tablename__ = "sections"

    writing_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("writings.id", ondelete="CASCADE"), nullable=False
    )
    title: Mapped[str | None] = mapped_column(String(500))
    content: Mapped[dict | None] = mapped_column(JSONB)
    canvas_data: Mapped[dict | None] = mapped_column(JSONB)
    # BigInteger because Flutter sends unsigned 32-bit ARGB values from
    # Color.toARGB32() (e.g. 0xFFFFB1DE = 4294924638), which overflow int32.
    section_color: Mapped[int | None] = mapped_column(BigInteger)
    # Author's per-chapter publish gate. The author can write infinitely
    # many sections; readers only see the ones the author has ticked +
    # republished. Body edits to an already-ticked section propagate
    # live (no republish), but adding or removing a section from the
    # public list is an explicit curation step.
    is_published: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )
    # Free-preview gate for paid books. When the source FeedItem has
    # `price_cents > 0`, only sections with `is_free_preview=True` are
    # readable to non-purchasers — every other published section is
    # gated. Ignored on free books (the price gate doesn't fire there).
    # Defaults to False so a paid book starts fully locked; the author
    # opts chapters into the preview from the publish dialog.
    is_free_preview: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )

    # --- Scrivener-class binder fields. All additive / nullable so legacy
    # rows keep working unchanged. `parent_id` references another section
    # in the same writing — kept as String (not FK) to avoid a
    # write-order chicken-and-egg with bulk inserts.
    parent_id: Mapped[str | None] = mapped_column(String(64))
    sort_order: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    kind: Mapped[str | None] = mapped_column(String(32))
    synopsis: Mapped[str | None] = mapped_column(String(2000))
    notes: Mapped[str | None] = mapped_column(JSONB)
    label_color: Mapped[int | None] = mapped_column(BigInteger)
    keywords: Mapped[list[str] | None] = mapped_column(ARRAY(String))
    include_in_publish: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )

    # Ordered list of footnote bodies for this section. JSONB so we
    # store the whole list per upsert (matches the client's section
    # outbox: footnotes ride inside the same `upsertSection` payload as
    # title / content / synopsis). Each entry has the shape
    # ``{"id": str, "text": str, "createdAt": iso, "updatedAt": iso}``.
    # Visible numbers are derived from list order at render time, so
    # editing this column never forces a Quill delta rewrite.
    footnotes: Mapped[list[dict] | None] = mapped_column(JSONB)

    # TTS audiobook artefacts. Populated by `/api/admin/books/import`
    # from the `book_ingest.deploy` bundle. ``audio_url`` is the MP3
    # (32 kbps mono); ``audio_words_url`` is the faster-whisper word
    # alignment JSON used to highlight the current word in the reader.
    # ``audio_duration_s`` is denormalised so the scrubber renders
    # without fetching the words file. All four are nullable so plain
    # text-only chapters keep working.
    audio_url: Mapped[str | None] = mapped_column(String)
    audio_words_url: Mapped[str | None] = mapped_column(String)
    audio_duration_s: Mapped[float | None] = mapped_column(Float)
    voice_name: Mapped[str | None] = mapped_column(String(8))

    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    # Relationships
    writing: Mapped["Writing"] = relationship(back_populates="sections")  # noqa: F821

    __table_args__ = (
        # Reader list filter — partial index so we only walk published
        # rows when surfacing chapters to non-author viewers.
        Index(
            "ix_sections_published_writing",
            "writing_id",
            postgresql_where="is_published",
        ),
    )
