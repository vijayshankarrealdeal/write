import uuid
from datetime import datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import Boolean, DateTime, ForeignKey, Index, Integer, String, Text, func
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
    description: Mapped[str | None] = mapped_column(Text)
    image_url: Mapped[str | None] = mapped_column(Text)
    image_meta: Mapped[dict | None] = mapped_column(JSONB)
    genres: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    writing_types: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    tags: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    likes_count: Mapped[int] = mapped_column(Integer, default=0)
    comments_count: Mapped[int] = mapped_column(Integer, default=0)
    is_draft: Mapped[bool] = mapped_column(Boolean, default=True)
    sections: Mapped[list[dict] | None] = mapped_column(JSONB)

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
        # Recency feed: published items ordered by created_at.
        Index("ix_feed_items_published_recent", "is_draft", "created_at"),
        # Trending feed and recommendation popularity scoring.
        Index("ix_feed_items_published_likes", "is_draft", "likes_count"),
        # By-author lookups (used by /api/feed/by-author and recommendation
        # candidate filters that exclude self-authored items).
        Index("ix_feed_items_author_published", "author_id", "is_draft"),
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
