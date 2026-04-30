"""Schema-only tests for the analytics ingest router and table.

These don't boot Postgres — they pin the Pydantic surface, the column
set on `analytics_events`, and the router's auth dependency wiring.
End-to-end ingest is exercised by the Flutter `AnalyticsService` tests
plus manual QA against a real backend.
"""
from __future__ import annotations

from datetime import datetime, timezone

import pytest
from pydantic import ValidationError

from app.auth.deps import get_optional_user
from app.models.analytics import AnalyticsEvent
from app.routers import analytics as analytics_router
from app.schemas.analytics import (
    AnalyticsBatchIn,
    AnalyticsEventIn,
    AnalyticsIngestResponse,
)


def test_analytics_event_table_columns():
    """Migration columns are load-bearing for every behavioural query —
    pin the set so a silent rename doesn't break dashboards."""
    cols = {c.name for c in AnalyticsEvent.__table__.columns}
    expected = {
        "id",
        "user_id",
        "client_id",
        "session_id",
        "event_name",
        "screen",
        "action",
        "entity_type",
        "entity_id",
        "source_screen",
        "duration_ms",
        "properties",
        "client_ts",
        "server_ts",
        "user_agent",
        "ip",
    }
    assert expected.issubset(cols), f"missing: {expected - cols}"


def test_analytics_event_indexes_present():
    """The user/event/client/session/properties indexes are what makes
    behavioural queries cheap. Pin the names so a future migration
    rename doesn't silently regress query plans."""
    idx = {i.name for i in AnalyticsEvent.__table__.indexes}
    assert "ix_analytics_events_user_server_ts" in idx
    assert "ix_analytics_events_event_server_ts" in idx
    assert "ix_analytics_events_client_server_ts" in idx
    assert "ix_analytics_events_session_server_ts" in idx
    assert "ix_analytics_events_properties_gin" in idx


def test_event_in_minimal_payload_validates():
    ev = AnalyticsEventIn(
        client_id="c-123",
        session_id="s-456",
        event_name="auth_login_viewed",
        client_ts=datetime(2026, 4, 30, 12, 0, tzinfo=timezone.utc),
    )
    assert ev.event_name == "auth_login_viewed"
    assert ev.properties == {}


def test_event_in_rejects_oversized_properties():
    big = {"k": "x" * 5000}  # > 4 KiB cap
    with pytest.raises(ValidationError):
        AnalyticsEventIn(
            client_id="c",
            session_id="s",
            event_name="x",
            properties=big,
            client_ts=datetime.now(tz=timezone.utc),
        )


def test_batch_in_size_bounds():
    one = AnalyticsEventIn(
        client_id="c",
        session_id="s",
        event_name="x",
        client_ts=datetime.now(tz=timezone.utc),
    )
    # Empty batch is rejected
    with pytest.raises(ValidationError):
        AnalyticsBatchIn(events=[])
    # 100 is the cap; 101 must be rejected
    with pytest.raises(ValidationError):
        AnalyticsBatchIn(events=[one] * 101)
    # 100 is fine
    AnalyticsBatchIn(events=[one] * 100)


def test_router_uses_optional_auth():
    """Anonymous events must flow — the router has to depend on the
    optional auth flavour, not the strict one."""
    import inspect

    sig = inspect.signature(analytics_router.ingest_events)
    user_param = sig.parameters["user"]
    # Default is a Depends(...) wrapping get_optional_user — unwrap.
    assert user_param.default.dependency is get_optional_user


def test_ingest_response_shape():
    r = AnalyticsIngestResponse(accepted=3)
    assert r.accepted == 3
    assert r.stitched_user_id is None
    assert r.stitched_count == 0
