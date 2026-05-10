import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, Index, String, Text, func
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UUIDMixin


class User(UUIDMixin, Base):
    __tablename__ = "users"

    email: Mapped[str] = mapped_column(String(320), unique=True, nullable=False)
    name: Mapped[str | None] = mapped_column(String(255))
    password_hash: Mapped[str | None] = mapped_column(Text)
    photo_url: Mapped[str | None] = mapped_column(Text)
    photo_meta: Mapped[dict | None] = mapped_column(JSONB)
    onboarding_complete: Mapped[bool] = mapped_column(Boolean, default=False)
    onboarding_data: Mapped[dict | None] = mapped_column(JSONB)

    # Public profile copy. `bio` is free-text shown on the author profile
    # page; `social_links` is a flat map of well-known platform → URL/
    # handle (`website`, `twitter`, `instagram`, `github`, `linkedin`).
    # Both are visible to anyone who can see the user, so write-side
    # length / sanity checks live in the schema layer.
    bio: Mapped[str | None] = mapped_column(Text)
    social_links: Mapped[dict | None] = mapped_column(JSONB)

    likes: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    reading_list: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    saved_posts: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    favorite_posts: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    section_bookmarks: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)

    # Stripe Connect (Express) account. Populated after the author
    # completes hosted onboarding. `stripe_charges_enabled` mirrors the
    # `charges_enabled` flag from the Account object — only true once
    # the author has cleared identity verification, at which point
    # destination charges can route money into their balance at the
    # moment of charge (minus our `application_fee_amount`). Both fields
    # are null for readers who never opt into selling.
    stripe_account_id: Mapped[str | None] = mapped_column(String(64))
    stripe_charges_enabled: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )

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
    bookmarks: Mapped[list["Bookmark"]] = relationship(back_populates="user", cascade="all, delete-orphan")  # noqa: F821
    author_bookmarks: Mapped[list["AuthorBookmark"]] = relationship(back_populates="user", cascade="all, delete-orphan")  # noqa: F821

    __table_args__ = (
        # Collaborative filtering pivots on "find users whose `likes` array
        # overlaps with mine." Without GIN, that's a full table scan.
        Index("ix_users_likes_gin", "likes", postgresql_using="gin"),
    )
