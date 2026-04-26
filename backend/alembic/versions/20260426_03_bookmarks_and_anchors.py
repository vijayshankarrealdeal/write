"""Phase 3 (P2): bookmarks table + reading_progress anchor columns.

Revision ID: 20260426_03
Revises: 20260426_02
Create Date: 2026-04-26
"""
from __future__ import annotations

from alembic import op

revision = "20260426_03"
down_revision = "20260426_02"
branch_labels = None
depends_on = None


# Idempotent raw-SQL form: the lifespan handler in app/main.py already adds
# `last_section_id` / `last_anchor` via `ADD COLUMN IF NOT EXISTS`, and the
# bookmarks table is registered on `Base` so it may already exist on prod.
def upgrade() -> None:
    op.execute(
        "ALTER TABLE reading_progress "
        "ADD COLUMN IF NOT EXISTS last_section_id VARCHAR(64)"
    )
    op.execute(
        "ALTER TABLE reading_progress "
        "ADD COLUMN IF NOT EXISTS last_anchor JSONB"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_reading_progress_user_last_read "
        "ON reading_progress (user_id, last_read_at)"
    )

    op.execute(
        """
        CREATE TABLE IF NOT EXISTS bookmarks (
            id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            feed_item_id UUID NOT NULL REFERENCES feed_items(id) ON DELETE CASCADE,
            section_id VARCHAR(64),
            section_index INTEGER NOT NULL DEFAULT 0,
            anchor JSONB NOT NULL,
            label VARCHAR(120),
            color VARCHAR(10) NOT NULL DEFAULT '#FFB300',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT uq_bookmark_anchor UNIQUE (user_id, feed_item_id, section_index, anchor)
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_bookmarks_user_feed_item "
        "ON bookmarks (user_id, feed_item_id)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_bookmarks_user_updated "
        "ON bookmarks (user_id, updated_at)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_bookmarks_user_updated")
    op.execute("DROP INDEX IF EXISTS ix_bookmarks_user_feed_item")
    op.execute("DROP TABLE IF EXISTS bookmarks")
    op.execute("DROP INDEX IF EXISTS ix_reading_progress_user_last_read")
    op.execute("ALTER TABLE reading_progress DROP COLUMN IF EXISTS last_anchor")
    op.execute("ALTER TABLE reading_progress DROP COLUMN IF EXISTS last_section_id")
