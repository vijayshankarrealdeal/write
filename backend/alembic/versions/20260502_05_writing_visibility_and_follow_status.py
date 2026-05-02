"""Per-writing visibility + follow approval status.

Revision ID: 20260502_05
Revises: 20260502_04
Create Date: 2026-05-02

Adds two columns that together implement Instagram-style per-writing privacy:

- `feed_items.visibility` ('public' | 'private', default 'public') — the
  audience gate for a published feed item. `is_draft` controls whether the
  item is live at all; `visibility` decides who among authenticated users is
  allowed to read a live item.
- `follows.status` ('pending' | 'approved', default 'approved') — turns the
  Twitter-style open follow graph into an Instagram-style approval graph.
  Existing rows default to 'approved' so previously open follows keep
  working without a backfill.

Adds a partial index on `follows (followee_id, created_at) WHERE status =
'pending'` so the author's pending-requests inbox is cheap to walk.
"""
from __future__ import annotations

from alembic import op


revision = "20260502_05"
down_revision = "20260502_04"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE feed_items "
        "ADD COLUMN IF NOT EXISTS visibility TEXT NOT NULL DEFAULT 'public'"
    )
    op.execute(
        "ALTER TABLE feed_items "
        "ADD CONSTRAINT ck_feed_items_visibility "
        "CHECK (visibility IN ('public', 'private'))"
    )
    op.execute(
        "ALTER TABLE follows "
        "ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'approved'"
    )
    op.execute(
        "ALTER TABLE follows "
        "ADD CONSTRAINT ck_follows_status "
        "CHECK (status IN ('pending', 'approved'))"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_follows_pending_inbox "
        "ON follows (followee_id, created_at) WHERE status = 'pending'"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_follows_follower_approved "
        "ON follows (follower_id, followee_id) WHERE status = 'approved'"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_follows_follower_approved")
    op.execute("DROP INDEX IF EXISTS ix_follows_pending_inbox")
    op.execute("ALTER TABLE follows DROP CONSTRAINT IF EXISTS ck_follows_status")
    op.execute("ALTER TABLE follows DROP COLUMN IF EXISTS status")
    op.execute("ALTER TABLE feed_items DROP CONSTRAINT IF EXISTS ck_feed_items_visibility")
    op.execute("ALTER TABLE feed_items DROP COLUMN IF EXISTS visibility")
