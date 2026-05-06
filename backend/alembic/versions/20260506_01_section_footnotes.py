"""Add per-section footnotes JSONB column.

Revision ID: 20260506_01
Revises: 20260504_02
Create Date: 2026-05-06

P1 #5 — footnotes (inline + inspector panel).

A section now owns an ordered list of footnote bodies. The visible
``¹², ³`` markers in the prose are stable-id Quill embeds; the visible
number is derived from this list's order at render time so reorder /
delete never rewrites the Quill delta. Storing the list as JSONB on
the row keeps the existing ``upsertSection`` outbox path intact —
footnotes ride alongside title / content / synopsis in the same write.

The column is nullable; legacy sections come back as ``NULL`` and the
client falls through to an empty list.

Idempotent (``IF NOT EXISTS`` / ``IF EXISTS``) so dev DBs that came up
through ``Base.metadata.create_all`` aren't double-bumped.
"""
from __future__ import annotations

from alembic import op


revision = "20260506_01"
down_revision = "20260504_02"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE sections "
        "ADD COLUMN IF NOT EXISTS footnotes JSONB"
    )


def downgrade() -> None:
    op.execute(
        "ALTER TABLE sections "
        "DROP COLUMN IF EXISTS footnotes"
    )
