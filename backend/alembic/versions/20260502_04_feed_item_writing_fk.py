"""Link feed_items to writings with ON DELETE CASCADE.

Revision ID: 20260502_04
Revises: 20260502_03
Create Date: 2026-05-02

Before this revision, publishing a writing copied its content into a brand
new feed_items row with no link back to the writing. Deleting the writing
left the feed card live, with a `bookId` reference that pointed at nothing
and crashed the reader when opened.

Adds `writing_id UUID UNIQUE NULL REFERENCES writings(id) ON DELETE CASCADE`
so the database itself drops the feed card when its source writing is
removed, and the publish dedupe path can find the existing card by
writing_id instead of guessing.
"""
from __future__ import annotations

from alembic import op


revision = "20260502_04"
down_revision = "20260502_03"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        ALTER TABLE feed_items
        ADD COLUMN IF NOT EXISTS writing_id UUID
        REFERENCES writings(id) ON DELETE CASCADE
        """
    )
    op.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_feed_items_writing_id "
        "ON feed_items (writing_id) WHERE writing_id IS NOT NULL"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_feed_items_writing_id "
        "ON feed_items (writing_id)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_feed_items_writing_id")
    op.execute("DROP INDEX IF EXISTS uq_feed_items_writing_id")
    op.execute("ALTER TABLE feed_items DROP COLUMN IF EXISTS writing_id")
