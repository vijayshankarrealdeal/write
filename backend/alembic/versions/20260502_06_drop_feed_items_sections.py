"""Drop feed_items.sections JSONB snapshot.

Revision ID: 20260502_06
Revises: 20260502_05
Create Date: 2026-05-02

The `feed_items.sections` JSONB column was a denormalised snapshot of
each chapter's title + Quill content, taken at publish time. It made
the public-read path one-table cheap, but the snapshot semantic was
the wrong default for InkSpaceX's serial-content product:

* New chapters needed a republish to reach readers.
* Typo fixes / errata didn't propagate without an explicit re-snapshot.
* Removing a chapter required republish to drop it from the public card.

Authors expected Substack/Wattpad-like behaviour: edit a chapter, the
fix is live next time the reader pulls. Reads now go through
`app.feed_sections` which joins `writings.section_ids[]` to the
`sections` table — the canonical source of truth — so author edits
propagate without a republish step.

The downgrade re-adds the column as nullable JSONB but does NOT
backfill it; downstream consumers that depend on the JSONB read path
must re-publish to repopulate.
"""
from __future__ import annotations

from alembic import op


revision = "20260502_06"
down_revision = "20260502_05"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE feed_items DROP COLUMN IF EXISTS sections")


def downgrade() -> None:
    op.execute("ALTER TABLE feed_items ADD COLUMN IF NOT EXISTS sections JSONB")
