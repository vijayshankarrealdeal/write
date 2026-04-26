import uuid
from datetime import datetime

from sqlalchemy import BigInteger, DateTime, ForeignKey, String, func
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

    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    # Relationships
    writing: Mapped["Writing"] = relationship(back_populates="sections")  # noqa: F821
