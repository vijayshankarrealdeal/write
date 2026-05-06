"""P1 #6: author_bookmarks table.

Distinct from the existing `bookmarks` table (reader-side, anchored to a
feed item + paragraph). Author bookmarks live on draft sections — the
writer flags a spot to come back to. Offset is a single character
position into the section's plain-text view; the client recomputes it
locally via Quill delta math when text is inserted/deleted before the
marker, then flushes the new offset through the outbox.

Revision ID: 20260506_02
Revises: 20260506_01
Create Date: 2026-05-06
"""
from __future__ import annotations

from alembic import op

revision = "20260506_02"
down_revision = "20260506_01"
branch_labels = None
depends_on = None


# Idempotent raw-SQL form: `Base.metadata.create_all` in the lifespan
# handler also creates this table on a fresh dev DB, so `IF NOT EXISTS`
# lets the migration land cleanly on environments that bootstrapped
# without it.
def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS author_bookmarks (
            id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            writing_id UUID NOT NULL REFERENCES writings(id) ON DELETE CASCADE,
            section_id VARCHAR(64) NOT NULL,
            "offset" INTEGER NOT NULL DEFAULT 0,
            label VARCHAR(120),
            color VARCHAR(10) NOT NULL DEFAULT '#FFB300',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT uq_author_bookmark_offset
                UNIQUE (user_id, section_id, "offset")
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_author_bookmarks_user_section "
        "ON author_bookmarks (user_id, section_id)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_author_bookmarks_user_writing "
        "ON author_bookmarks (user_id, writing_id)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_author_bookmarks_user_writing")
    op.execute("DROP INDEX IF EXISTS ix_author_bookmarks_user_section")
    op.execute("DROP TABLE IF EXISTS author_bookmarks")
