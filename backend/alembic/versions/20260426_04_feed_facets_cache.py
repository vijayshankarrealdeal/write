"""Phase 2 (P2): nightly-rebuilt facet count cache.

Revision ID: 20260426_04
Revises: 20260426_03
Create Date: 2026-04-26

Adds the `feed_facets` cache table promised in p2.md §Phase 2 — read by
`/api/feed/facets` once the published-item count crosses ~50k where the
live `unnest + group by` over `feed_items` starts to bite.

Schema is intentionally minimal: `(kind, value, count, refreshed_at)`.
The nightly job in `backend/scripts/refresh_feed_facets.py` truncates +
repopulates atomically; reads pick whichever generation is newest.
"""
from __future__ import annotations

from alembic import op


revision = "20260426_04"
down_revision = "20260426_03"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS feed_facets (
            kind VARCHAR(16) NOT NULL,
            value VARCHAR(64) NOT NULL,
            count INTEGER NOT NULL,
            refreshed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (kind, value)
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_feed_facets_kind_count "
        "ON feed_facets (kind, count DESC)"
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS feed_facets")
