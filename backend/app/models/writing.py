import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String, Text, func
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UUIDMixin


class Writing(UUIDMixin, Base):
    __tablename__ = "writings"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    title: Mapped[str | None] = mapped_column(String(500))
    author: Mapped[str | None] = mapped_column(String(255))
    description: Mapped[str | None] = mapped_column(Text)
    cover_image_path: Mapped[str | None] = mapped_column(Text)
    cover_image_meta: Mapped[dict | None] = mapped_column(JSONB)
    status: Mapped[str | None] = mapped_column(String(50))
    writing_type: Mapped[str | None] = mapped_column(String(100))
    subtype: Mapped[str | None] = mapped_column(String(100))
    section_ids: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)

    # Scrivener-class project metadata. All optional — legacy projects
    # keep working without these.
    target_word_count: Mapped[int | None] = mapped_column(Integer)
    target_deadline: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    label_meaning: Mapped[str | None] = mapped_column(String(64))
    # ARGB int → human name. JSONB lets us store an arbitrary palette
    # without a side table.
    label_names: Mapped[dict | None] = mapped_column(JSONB)

    # Paginated-view configuration (page size, margins, font, line
    # spacing). Stored as a JSONB blob so the shape can grow without
    # a schema migration. Null on legacy projects → client falls
    # back to PageLayoutSettings.standard.
    page_layout: Mapped[dict | None] = mapped_column(JSONB)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    # Relationships
    user: Mapped["User"] = relationship(back_populates="writings")  # noqa: F821
    sections: Mapped[list["Section"]] = relationship(back_populates="writing", cascade="all, delete-orphan")  # noqa: F821
