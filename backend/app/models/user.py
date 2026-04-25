import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, String, Text, func
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UUIDMixin


class User(UUIDMixin, Base):
    __tablename__ = "users"

    email: Mapped[str] = mapped_column(String(320), unique=True, nullable=False)
    name: Mapped[str | None] = mapped_column(String(255))
    password_hash: Mapped[str | None] = mapped_column(Text)
    photo_url: Mapped[str | None] = mapped_column(Text)
    onboarding_complete: Mapped[bool] = mapped_column(Boolean, default=False)
    onboarding_data: Mapped[dict | None] = mapped_column(JSONB)

    likes: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    reading_list: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    saved_posts: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    favorite_posts: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    section_bookmarks: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    # Relationships
    writings: Mapped[list["Writing"]] = relationship(back_populates="user", cascade="all, delete-orphan")  # noqa: F821
    feed_items: Mapped[list["FeedItem"]] = relationship(back_populates="author_user")  # noqa: F821
    bookshelves: Mapped[list["Bookshelf"]] = relationship(back_populates="user", cascade="all, delete-orphan")  # noqa: F821
    highlights: Mapped[list["Highlight"]] = relationship(back_populates="user", cascade="all, delete-orphan")  # noqa: F821
    reading_progress: Mapped[list["ReadingProgress"]] = relationship(back_populates="user", cascade="all, delete-orphan")  # noqa: F821
