"""Notifications + push subscriptions tables.

Revision ID: 20260426_02
Revises: 20260426_01
Create Date: 2026-04-26
"""
from __future__ import annotations

from alembic import op

revision = "20260426_02"
down_revision = "20260426_01"
branch_labels = None
depends_on = None


# Idempotent raw-SQL form: prod DBs may already have these tables from a
# previous `Base.metadata.create_all` run, so plain `op.create_table` would
# fail with "relation already exists". `IF NOT EXISTS` makes re-runs safe.
def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS notifications (
            id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            kind VARCHAR(32) NOT NULL,
            actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
            actor_name VARCHAR(255),
            actor_photo_url TEXT,
            feed_item_id UUID REFERENCES feed_items(id) ON DELETE CASCADE,
            feed_item_title VARCHAR(512),
            data JSONB,
            read BOOLEAN NOT NULL DEFAULT FALSE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_notifications_user_id "
        "ON notifications (user_id)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_notifications_created_at "
        "ON notifications (created_at)"
    )

    op.execute(
        """
        CREATE TABLE IF NOT EXISTS push_subscriptions (
            id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            platform VARCHAR(16) NOT NULL,
            token TEXT NOT NULL,
            device_label VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT uq_push_subscriptions_user_token UNIQUE (user_id, token)
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_push_subscriptions_user_id "
        "ON push_subscriptions (user_id)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_push_subscriptions_user_id")
    op.execute("DROP TABLE IF EXISTS push_subscriptions")
    op.execute("DROP INDEX IF EXISTS ix_notifications_created_at")
    op.execute("DROP INDEX IF EXISTS ix_notifications_user_id")
    op.execute("DROP TABLE IF EXISTS notifications")
