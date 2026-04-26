"""Enable pgvector and add feed_items.embedding column.

Revision ID: 20260426_01
Revises:
Create Date: 2026-04-26
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from pgvector.sqlalchemy import Vector

revision = "20260426_01"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS vector")
    op.add_column(
        "feed_items",
        sa.Column("embedding", Vector(1536), nullable=True),
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS idx_feed_items_embedding "
        "ON feed_items USING ivfflat (embedding vector_cosine_ops) "
        "WITH (lists = 100)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS idx_feed_items_embedding")
    op.drop_column("feed_items", "embedding")
