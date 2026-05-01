"""User block list.

Revision ID: 20260502_02
Revises: 20260502_01
Create Date: 2026-05-02

A block is one-directional: when A blocks B, A's content is hidden from
B and B can no longer follow A. The follow router consults this table
to refuse new follows and to drop any existing follow pair when a
block is created.
"""
from __future__ import annotations

from alembic import op


revision = "20260502_02"
down_revision = "20260502_01"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS blocks (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            blocker_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            blockee_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT uq_blocks_pair UNIQUE (blocker_id, blockee_id),
            CONSTRAINT ck_blocks_not_self CHECK (blocker_id <> blockee_id)
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_blocks_blocker_created "
        "ON blocks (blocker_id, created_at)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_blocks_blockee ON blocks (blockee_id)"
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS blocks")
