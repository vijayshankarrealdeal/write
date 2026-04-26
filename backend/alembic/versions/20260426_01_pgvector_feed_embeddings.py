"""Enable pgvector and add feed_items.embedding column.

Revision ID: 20260426_01
Revises:
Create Date: 2026-04-26
"""
from __future__ import annotations

from alembic import op

revision = "20260426_01"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Idempotent: prod DBs were created by `Base.metadata.create_all` before
    # this migration existed, so the column may or may not be present.
    op.execute("CREATE EXTENSION IF NOT EXISTS vector")
    op.execute(
        "ALTER TABLE feed_items ADD COLUMN IF NOT EXISTS embedding vector(1536)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS idx_feed_items_embedding "
        "ON feed_items USING ivfflat (embedding vector_cosine_ops) "
        "WITH (lists = 100)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS idx_feed_items_embedding")
    op.drop_column("feed_items", "embedding")
