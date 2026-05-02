import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Index, String, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDMixin


class Follow(UUIDMixin, Base):
    __tablename__ = "follows"

    follower_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    followee_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    # 'pending' until the followee approves; 'approved' grants the follower
    # access to the followee's `visibility='private'` feed items. Default
    # 'approved' keeps the open-follow path working when the target user
    # has no private content (decided at request time, not at column level).
    status: Mapped[str] = mapped_column(
        String(16), nullable=False, default="approved", server_default="approved"
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (
        UniqueConstraint("follower_id", "followee_id", name="uq_follows_pair"),
        CheckConstraint("follower_id <> followee_id", name="ck_follows_not_self"),
        CheckConstraint("status IN ('pending', 'approved')", name="ck_follows_status"),
        Index("ix_follows_followee_created", "followee_id", "created_at"),
        Index("ix_follows_follower_created", "follower_id", "created_at"),
        # Partial index for the author's pending inbox.
        Index(
            "ix_follows_pending_inbox",
            "followee_id",
            "created_at",
            postgresql_where="status = 'pending'",
        ),
        # Partial index for the visibility predicate's hot path
        # (does *this* follower have an approved row against *this* author).
        Index(
            "ix_follows_follower_approved",
            "follower_id",
            "followee_id",
            postgresql_where="status = 'approved'",
        ),
    )
