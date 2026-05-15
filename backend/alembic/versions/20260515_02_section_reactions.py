"""Per-section emoji reactions.

A reader hits ❤ on a chapter; another reader sees the count climb.
Granularity is the section (chapter), not the paragraph — paragraph-
level reactions are a Phase 2 problem because mapping a Quill delta
op-index across edits is fiddly.

Schema:
* ``section_reactions.section_id`` — FK to sections, cascade on delete.
* ``section_reactions.user_id`` — FK to users, cascade on delete.
* ``section_reactions.emoji`` — short string. Restricted client-side
  to a fixed picker set; we keep it loose here so a future picker
  expansion doesn't need a migration.
* Unique on ``(section_id, user_id, emoji)`` so the same user can't
  spam the same emoji on the same section, and POST is idempotent.

Index ``ix_section_reactions_section`` keeps the per-section
aggregate query (``SELECT emoji, count(*) GROUP BY emoji``) cheap.

Revision ID: 20260515_02
Revises: 20260515_01
Create Date: 2026-05-15
"""
from __future__ import annotations

from alembic import op


revision = "20260515_02"
down_revision = "20260515_01"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS section_reactions (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            section_id UUID NOT NULL
                REFERENCES sections(id) ON DELETE CASCADE,
            user_id UUID NOT NULL
                REFERENCES users(id) ON DELETE CASCADE,
            emoji VARCHAR(16) NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        );
        """
    )
    op.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_section_reactions_section_user_emoji "
        "ON section_reactions (section_id, user_id, emoji);"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_section_reactions_section "
        "ON section_reactions (section_id);"
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS section_reactions;")
