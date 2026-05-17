"""Add finished_at to reading_progress + an index for the library view.

Today ``reading_progress.completed`` is a bool that flips on the
"Mark as read" tap (or — once the auto-completion trigger ships — when
the reader scrolls to the last paragraph of the last section). We knew
*that* it flipped but not *when*, so the Library / History views can't
say "you finished this on May 14" and the Re-read label has nothing to
key off.

This migration:

* Adds ``finished_at TIMESTAMPTZ NULL`` to ``reading_progress``.
* Backfills existing ``completed=true`` rows with their ``last_read_at``
  as a best-effort proxy (the only timestamp we have on those rows; it
  will be off by a few seconds but right to the day, which is all the
  Library view needs).
* Adds ``ix_reading_progress_user_finished`` keyed on
  ``(user_id, finished_at DESC)`` so the ``label=finished`` library
  query is one index walk.

Nullable + backfilled means no read-path breakage and the
``compute_reader_tier`` aggregations keep working unchanged.

Revision ID: 20260517_01
Revises: 20260516_01
Create Date: 2026-05-17
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op


revision = "20260517_01"
down_revision = "20260516_01"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "reading_progress",
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
    )
    # Backfill so the Library view can already display dates for rows
    # that were marked completed before this column existed. last_read_at
    # is the only timestamp on the row; close enough.
    op.execute("""
        UPDATE reading_progress
        SET finished_at = last_read_at
        WHERE completed = TRUE AND finished_at IS NULL
    """)
    # Library "Finished" tab orders by finished_at DESC.
    op.create_index(
        "ix_reading_progress_user_finished",
        "reading_progress",
        ["user_id", sa.text("finished_at DESC")],
    )


def downgrade() -> None:
    op.drop_index("ix_reading_progress_user_finished", table_name="reading_progress")
    op.drop_column("reading_progress", "finished_at")
