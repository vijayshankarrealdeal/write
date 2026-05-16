"""Composite index on recommendation_events for the seen-filter query.

The home-feed dedup pass (``app.ai.signals.seen.get_recently_seen_ids``)
runs ``WHERE user_id = ? AND event_type = 'impression' AND created_at >
?`` on every personalised feed request. The existing
``ix_rec_events_user_created`` is keyed on ``(user_id, created_at)``
and forces Postgres to filter ``event_type`` row-by-row, which on a
prod-sized log (millions of impressions) is the difference between
sub-millisecond and several hundred milliseconds.

Adding ``(user_id, event_type, created_at DESC)`` lets the planner
walk the impression slice for one user in index order, picking up the
``DISTINCT feed_item_id`` aggregation as a free side effect of the
``created_at`` direction.

The index is built ``CONCURRENTLY`` because the table is hot — a
``CREATE INDEX`` without ``CONCURRENTLY`` takes an ``ACCESS EXCLUSIVE``
lock that would briefly stall every analytics write. ``CONCURRENTLY``
cannot run inside a transaction block, hence ``transactional_ddl =
False`` below and the bare ``op.execute`` calls.

Revision ID: 20260516_01
Revises: 20260515_02
Create Date: 2026-05-16
"""
from __future__ import annotations

from alembic import op


revision = "20260516_01"
down_revision = "20260515_02"
branch_labels = None
depends_on = None

# CREATE INDEX CONCURRENTLY refuses to run inside a transaction; tell
# Alembic to skip its default BEGIN/COMMIT wrapper for this migration.
transactional_ddl = False


def upgrade() -> None:
    op.execute(
        "CREATE INDEX CONCURRENTLY IF NOT EXISTS "
        "ix_rec_events_user_type_time "
        "ON recommendation_events (user_id, event_type, created_at DESC)"
    )


def downgrade() -> None:
    op.execute(
        "DROP INDEX CONCURRENTLY IF EXISTS ix_rec_events_user_type_time"
    )
