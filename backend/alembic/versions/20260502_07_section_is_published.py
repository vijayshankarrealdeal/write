"""Section.is_published — per-chapter publish gate.

Revision ID: 20260502_07
Revises: 20260502_06
Create Date: 2026-05-02

The author owns a writing with N sections (chapters). They tick which
ones to include when publishing, and only ticked sections are visible
to readers. Adding/removing/reordering chapters requires a republish to
take effect (the author's explicit curation step). Content edits to
already-ticked chapters propagate live — no republish needed.

This column is what reader-side helpers
(`app.feed_sections.list_section_stubs` etc.) filter on. The author's
own editor view is unaffected; they keep seeing every section they own.

Backfill: any section under a writing that already has a non-draft
FeedItem is set to is_published=True. Matches the prior behavior where
publishing the FeedItem implicitly published every section. If you
wiped the DB before this revision, the backfill is a no-op.

A partial index on `(writing_id) WHERE is_published` keeps the reader
list cheap when a writing has many drafted-but-not-yet-published
chapters.
"""
from __future__ import annotations

from alembic import op


revision = "20260502_07"
down_revision = "20260502_06"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE sections "
        "ADD COLUMN IF NOT EXISTS is_published BOOLEAN NOT NULL DEFAULT FALSE"
    )
    # Backfill: preserve existing public state — anything under a
    # non-draft FeedItem was implicitly visible before this column
    # existed, so flip those to TRUE.
    op.execute(
        """
        UPDATE sections AS s
           SET is_published = TRUE
         WHERE EXISTS (
                 SELECT 1 FROM feed_items f
                  WHERE f.writing_id = s.writing_id
                    AND f.is_draft = FALSE
               )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_sections_published_writing "
        "ON sections (writing_id) WHERE is_published"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_sections_published_writing")
    op.execute("ALTER TABLE sections DROP COLUMN IF EXISTS is_published")
