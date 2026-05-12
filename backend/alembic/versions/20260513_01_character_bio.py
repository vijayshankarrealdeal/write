"""Add bio column to book_characters for a "who is this" caption.

The existing `appearance` column is the scout's image-generation
prompt — locks in hair / build / clothing for the art model. It
reads as a prompt ("a tall, gaunt man in his late 30s with sharp
hawk-like nose…") not as a character card a reader would expect on
a detail page.

`bio` is the new 2-3 sentence biography the scout writes alongside
the appearance: who the character is, their role in the book,
personality / motivations, without major spoilers. The Flutter
character page surfaces this instead of the appearance text.

Nullable so legacy rows survive — the client falls back to the
appearance string when bio is missing.

Revision ID: 20260513_01
Revises: 20260512_01
Create Date: 2026-05-13
"""
from __future__ import annotations

from alembic import op


revision = "20260513_01"
down_revision = "20260512_01"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE book_characters ADD COLUMN IF NOT EXISTS bio TEXT"
    )


def downgrade() -> None:
    op.execute("ALTER TABLE book_characters DROP COLUMN IF EXISTS bio")
