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
cannot run inside a transaction block; ``op.get_context().autocommit_block()``
is Alembic's canonical way to step out of the surrounding transaction
for a single statement (a module-level ``transactional_ddl = False``
is *not* honoured — that's a ``MigrationContext`` option, not a
per-revision one).

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


def upgrade() -> None:
    # `autocommit_block` commits the surrounding migration transaction,
    # flips the connection into autocommit for the body, then resumes
    # the normal transactional flow — the only way `CONCURRENTLY` works
    # under Alembic + asyncpg without disabling transactional DDL for
    # the whole env.
    with op.get_context().autocommit_block():
        op.execute(
            "CREATE INDEX CONCURRENTLY IF NOT EXISTS "
            "ix_rec_events_user_type_time "
            "ON recommendation_events (user_id, event_type, created_at DESC)"
        )


def downgrade() -> None:
    with op.get_context().autocommit_block():
        op.execute(
            "DROP INDEX CONCURRENTLY IF EXISTS ix_rec_events_user_type_time"
        )
