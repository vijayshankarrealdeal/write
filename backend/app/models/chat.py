"""One-on-one chat: conversations and messages.

A conversation is the persistent thread between two users. We canonicalize
the pair (lower-id stored as `user_a`, higher-id as `user_b`) so the
unique constraint dedupes regardless of who initiated. Messages carry a
`kind` discriminator so a single thread can mix plain text with richer
attachments — books, excerpts (lines from a book), sections, and images
— without per-kind tables. The attachment payload lives in JSONB so the
shape can evolve without migrations.
"""
import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDMixin


class Conversation(UUIDMixin, Base):
    __tablename__ = "conversations"

    user_a_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    user_b_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    last_message_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), index=True
    )
    last_message_preview: Mapped[str | None] = mapped_column(String(280))

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (
        UniqueConstraint("user_a_id", "user_b_id", name="uq_conversations_pair"),
        CheckConstraint("user_a_id < user_b_id", name="ck_conversations_canonical"),
        Index("ix_conversations_user_a_last", "user_a_id", "last_message_at"),
        Index("ix_conversations_user_b_last", "user_b_id", "last_message_at"),
    )


class ChatMessage(UUIDMixin, Base):
    __tablename__ = "chat_messages"

    conversation_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("conversations.id", ondelete="CASCADE"),
        nullable=False,
    )
    sender_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    # 'text' | 'image' | 'book' | 'excerpt' | 'section'
    kind: Mapped[str] = mapped_column(String(16), nullable=False, default="text")
    body: Mapped[str | None] = mapped_column(Text)
    attachment: Mapped[dict | None] = mapped_column(JSONB)

    read_by_recipient: Mapped[bool] = mapped_column(Boolean, default=False)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), index=True
    )

    __table_args__ = (
        Index(
            "ix_chat_messages_conversation_created",
            "conversation_id",
            "created_at",
        ),
    )
