"""Add bio + social_links columns to users.

Surface area for the public profile page: a free-text bio (up to a few
paragraphs) and a small JSONB map of platform → URL/handle so other
users can find the author elsewhere. Stored on `users` directly because
both fields are tiny, frequently read with the rest of the user record,
and only the user themselves writes them.

The `social_links` shape is intentionally a flat dict of well-known keys
(`website`, `twitter`, `instagram`, `github`, `linkedin`) to keep the
client UI straightforward and the JSON shape stable across versions.

Revision ID: 20260509_01
Revises: 20260506_02
Create Date: 2026-05-09
"""
from __future__ import annotations

from alembic import op


revision = "20260509_01"
down_revision = "20260506_02"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS bio TEXT"
    )
    op.execute(
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS social_links JSONB"
    )


def downgrade() -> None:
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS social_links")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS bio")
