import uuid
from datetime import datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import Boolean, CheckConstraint, DateTime, ForeignKey, Index, Integer, String, Text, func
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.config import settings
from app.models.base import Base, UUIDMixin


class FeedItem(UUIDMixin, Base):
    __tablename__ = "feed_items"

    title: Mapped[str | None] = mapped_column(String(500))
    author: Mapped[str | None] = mapped_column(String(255))
    author_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=False
    )
    # Source writing this feed item was published from. ON DELETE CASCADE
    # means deleting the writing also drops the feed item, so the public
    # feed never displays a card whose backing draft is gone.
    writing_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("writings.id", ondelete="CASCADE"),
        nullable=True,
        unique=True,
    )
    description: Mapped[str | None] = mapped_column(Text)
    image_url: Mapped[str | None] = mapped_column(Text)
    image_meta: Mapped[dict | None] = mapped_column(JSONB)
    genres: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    writing_types: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    tags: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    likes_count: Mapped[int] = mapped_column(Integer, default=0)
    comments_count: Mapped[int] = mapped_column(Integer, default=0)
    is_draft: Mapped[bool] = mapped_column(Boolean, default=True)
    # Price in the smallest currency unit (paise / cents). 0 means free
    # — the gate in `feed_sections` only kicks in for `price_cents > 0`
    # cards. Currency is an ISO-4217 code Razorpay accepts; we don't
    # enforce the set in the DB so a future price change to a new
    # currency doesn't need a migration.
    price_cents: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    currency: Mapped[str] = mapped_column(
        String(8), nullable=False, default="inr", server_default="inr"
    )
    # Audience gate among published items. 'public' = any authenticated user;
    # 'private' = author + approved followers (Instagram-style). The author
    # can flip this at any time. Independent of `is_draft`: both checks must
    # pass for a non-author to read the item.
    visibility: Mapped[str] = mapped_column(
        String(16), nullable=False, default="public", server_default="public"
    )
    # Note: the previous `sections: JSONB` snapshot was dropped in
    # migration 20260502_06. Section bodies live in the `sections`
    # table only, joined via Writing.section_ids[]. See
    # app.feed_sections for the read-through helpers.

    # Semantic embedding of `title + description + first ~2000 chars`. Populated
    # asynchronously when an item is published; null until the background task
    # finishes (or if Azure embeddings are unconfigured / fail).
    embedding: Mapped[list[float] | None] = mapped_column(
        Vector(settings.embedding_dim), nullable=True
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    # Relationships
    author_user: Mapped["User"] = relationship(back_populates="feed_items")  # noqa: F821
    comments: Mapped[list["Comment"]] = relationship(back_populates="feed_item", cascade="all, delete-orphan")  # noqa: F821

    __table_args__ = (
        CheckConstraint(
            "visibility IN ('public', 'private')",
            name="ck_feed_items_visibility",
        ),
        # Recency feed: published items ordered by created_at.
        Index("ix_feed_items_published_recent", "is_draft", "created_at"),
        # Trending feed and recommendation popularity scoring.
        Index("ix_feed_items_published_likes", "is_draft", "likes_count"),
        # By-author lookups (used by /api/feed/by-author and recommendation
        # candidate filters that exclude self-authored items).
        Index("ix_feed_items_author_published", "author_id", "is_draft"),
        # Lookup by source writing — drives the publish dedupe path so a
        # second publish updates the existing feed item instead of creating
        # a sibling.
        Index("ix_feed_items_writing_id", "writing_id"),
        # GIN indexes on the array columns so the recommendation engine can
        # filter candidates by genre/tag overlap without full-scanning.
        Index(
            "ix_feed_items_genres_gin",
            "genres",
            postgresql_using="gin",
        ),
        Index(
            "ix_feed_items_tags_gin",
            "tags",
            postgresql_using="gin",
        ),
        Index(
            "ix_feed_items_writing_types_gin",
            "writing_types",
            postgresql_using="gin",
        ),
        # IVFFlat index on the semantic embedding for cosine-distance KNN.
        # `lists=100` is a reasonable default for the catalogue size we expect
        # over the next year; revisit when row count crosses ~1M.
        Index(
            "idx_feed_items_embedding",
            "embedding",
            postgresql_using="ivfflat",
            postgresql_with={"lists": 100},
            postgresql_ops={"embedding": "vector_cosine_ops"},
        ),
    )
