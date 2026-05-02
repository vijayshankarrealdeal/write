import uuid
from datetime import datetime

from sqlalchemy import BigInteger, Boolean, DateTime, ForeignKey, Index, String, func
from sqlalchemy.dialects.postgresql import JSONB, UUID
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
