"""Add book_characters table for the reader-facing cast strip.

A book ingested through the test_model pipeline gets a "character
bible" from the scout phase plus one canonical portrait per character.
This migration gives those portraits a permanent home in the schema so
the Flutter book detail page can render a "Cast" strip above the
chapter list and link to per-character pages.

Books that don't have a character_bible (essay collections, landscape
travelogues, sacred texts) simply have zero rows in this table — the
client treats it as "no cast" and skips the strip.

Revision ID: 20260512_01
Revises: 20260511_01
Create Date: 2026-05-12
"""
from __future__ import annotations

from alembic import op


revision = "20260512_01"
down_revision = "20260511_01"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS book_characters (
            id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            writing_id      UUID NOT NULL REFERENCES writings(id) ON DELETE CASCADE,
            name            VARCHAR(200) NOT NULL,
            appearance      TEXT NOT NULL,
            image_url       TEXT,
            image_meta      JSONB,
            sort_order      INTEGER NOT NULL DEFAULT 0,
            created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
        );
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_book_characters_writing_sort "
        "ON book_characters (writing_id, sort_order);"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_book_characters_writing_sort;")
    op.execute("DROP TABLE IF EXISTS book_characters;")
