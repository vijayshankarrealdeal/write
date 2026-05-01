"""User follow graph.

Revision ID: 20260502_01
Revises: 20260430_01
Create Date: 2026-05-02

Backs the public profile follow / followers / following surface. The
unique pair index is what makes idempotent re-follows cheap; the
per-side composite indexes drive the followers/following list pages
(walk by `followee_id` or `follower_id`, sorted by `created_at`).
"""
from __future__ import annotations

from alembic import op


revision = "20260502_01"
down_revision = "20260430_01"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS follows (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            follower_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            followee_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT uq_follows_pair UNIQUE (follower_id, followee_id),
            CONSTRAINT ck_follows_not_self CHECK (follower_id <> followee_id)
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_follows_followee_created "
        "ON follows (followee_id, created_at)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_follows_follower_created "
        "ON follows (follower_id, created_at)"
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS follows")
