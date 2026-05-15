from datetime import datetime
from typing import Any
from uuid import UUID

from pydantic import BaseModel, Field, field_validator


_MAX_PROPERTY_BYTES = 4096
_MAX_BATCH = 100


class AnalyticsEventIn(BaseModel):
    """One event from the client.

    `client_id` and `session_id` are opaque strings the client owns —
    they're how we stitch a user's journey across login (anonymous →
    identified) and within a session.

    String fields are truncated server-side rather than rejected with
    422. Analytics are best-effort telemetry; losing one event to a
    deep route name like ``/post/<uuid>/section/<uuid>`` (which used
    to blow past the 120-char `screen` cap and produce a constant
    422-spam loop in the browser console) is far worse than storing
    a slightly truncated value. The truncation widths still match the
    underlying varchar(...) columns so the DB writes are clean.
    """

    client_id: str
    session_id: str
    event_name: str
    screen: str | None = None
    action: str | None = None
    entity_type: str | None = None
    entity_id: str | None = None
    source_screen: str | None = None
    duration_ms: int | None = Field(default=None, ge=0, le=24 * 60 * 60 * 1000)
    properties: dict[str, Any] = Field(default_factory=dict)
    client_ts: datetime

    # Per-field truncation. mode="before" runs before the type check so
    # we never see a string_too_long error from the upstream constraint.
    @field_validator("client_id", "session_id", mode="before")
    @classmethod
    def _truncate_64(cls, v):
        return v[:64] if isinstance(v, str) else v

    @field_validator("event_name", "entity_id", mode="before")
    @classmethod
    def _truncate_80(cls, v):
        return v[:80] if isinstance(v, str) else v

    @field_validator("screen", "source_screen", mode="before")
    @classmethod
    def _truncate_120(cls, v):
        return v[:120] if isinstance(v, str) else v

    @field_validator("action", mode="before")
    @classmethod
    def _truncate_20(cls, v):
        return v[:20] if isinstance(v, str) else v

    @field_validator("entity_type", mode="before")
    @classmethod
    def _truncate_40(cls, v):
        return v[:40] if isinstance(v, str) else v

    @field_validator("properties")
    @classmethod
    def _cap_properties_size(cls, v: dict[str, Any]) -> dict[str, Any]:
        # Drop the bag entirely if it's oversized rather than reject the
        # whole event. Same reasoning as the string truncation: an
        # event without properties is more useful than no event at all.
        import json

        try:
            size = len(json.dumps(v, default=str))
        except (TypeError, ValueError):
            return {}
        if size > _MAX_PROPERTY_BYTES:
            return {}
        return v


class AnalyticsBatchIn(BaseModel):
    """Batch ingest. The frontend always sends batches even of size 1
    so the wire format is uniform."""

    events: list[AnalyticsEventIn] = Field(min_length=1, max_length=_MAX_BATCH)


class AnalyticsIngestResponse(BaseModel):
    accepted: int
    stitched_user_id: UUID | None = None
    stitched_count: int = 0
