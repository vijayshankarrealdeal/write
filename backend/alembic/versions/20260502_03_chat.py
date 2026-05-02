"""One-on-one chat: conversations + messages.

Revision ID: 20260502_03
Revises: 20260502_02
Create Date: 2026-05-02

The conversation pair is canonicalized (user_a_id < user_b_id) so the
unique constraint dedupes regardless of who started the chat. Messages
carry a `kind` discriminator and a JSONB attachment payload so the same
table holds plain text alongside book/excerpt/section/image shares.
"""
from __future__ import annotations

from alembic import op


revision = "20260502_03"
down_revision = "20260502_02"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS conversations (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_a_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            user_b_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            last_message_at TIMESTAMPTZ,
            last_message_preview VARCHAR(280),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT uq_conversations_pair UNIQUE (user_a_id, user_b_id),
            CONSTRAINT ck_conversations_canonical CHECK (user_a_id < user_b_id)
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_conversations_last_message_at "
        "ON conversations (last_message_at)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_conversations_user_a_last "
        "ON conversations (user_a_id, last_message_at)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_conversations_user_b_last "
        "ON conversations (user_b_id, last_message_at)"
    )

    op.execute(
        """
        CREATE TABLE IF NOT EXISTS chat_messages (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            sender_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            kind VARCHAR(16) NOT NULL DEFAULT 'text',
            body TEXT,
            attachment JSONB,
            read_by_recipient BOOLEAN NOT NULL DEFAULT FALSE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_chat_messages_created_at "
        "ON chat_messages (created_at)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_chat_messages_conversation_created "
        "ON chat_messages (conversation_id, created_at)"
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS chat_messages")
    op.execute("DROP TABLE IF EXISTS conversations")
