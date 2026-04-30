"""User-behaviour analytics event log.

Revision ID: 20260430_01
Revises: 20260426_04
Create Date: 2026-04-30

Adds the `analytics_events` table that backs the
`AnalyticsService` ingest endpoint. See `app/models/analytics.py` for
the schema rationale.

The GIN index on `properties` is what makes "find every event whose
properties contain post_id=X" cheap; without it, behavioural drilldowns
fall back to seq scans the moment volume picks up.
"""
from __future__ import annotations

from alembic import op


revision = "20260430_01"
down_revision = "20260426_04"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS analytics_events (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id UUID REFERENCES users(id) ON DELETE SET NULL,
            client_id VARCHAR(64) NOT NULL,
            session_id VARCHAR(64) NOT NULL,
            event_name VARCHAR(80) NOT NULL,
            screen VARCHAR(120),
            action VARCHAR(20),
            entity_type VARCHAR(40),
            entity_id VARCHAR(80),
            source_screen VARCHAR(120),
            duration_ms INTEGER,
            properties JSONB NOT NULL DEFAULT '{}'::jsonb,
            client_ts TIMESTAMPTZ NOT NULL,
            server_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            user_agent VARCHAR(500),
            ip INET
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_analytics_events_user_server_ts "
        "ON analytics_events (user_id, server_ts)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_analytics_events_event_server_ts "
        "ON analytics_events (event_name, server_ts)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_analytics_events_client_server_ts "
        "ON analytics_events (client_id, server_ts)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_analytics_events_session_server_ts "
        "ON analytics_events (session_id, server_ts)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_analytics_events_properties_gin "
        "ON analytics_events USING gin (properties)"
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS analytics_events")
