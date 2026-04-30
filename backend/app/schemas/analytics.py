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
    identified) and within a session. Lengths are bounded to keep the
    table's varchar caps and indexes well-behaved.
    """

    client_id: str = Field(min_length=1, max_length=64)
    session_id: str = Field(min_length=1, max_length=64)
    event_name: str = Field(min_length=1, max_length=80)
    screen: str | None = Field(default=None, max_length=120)
    action: str | None = Field(default=None, max_length=20)
    entity_type: str | None = Field(default=None, max_length=40)
    entity_id: str | None = Field(default=None, max_length=80)
    source_screen: str | None = Field(default=None, max_length=120)
    duration_ms: int | None = Field(default=None, ge=0, le=24 * 60 * 60 * 1000)
    properties: dict[str, Any] = Field(default_factory=dict)
    client_ts: datetime

    @field_validator("properties")
    @classmethod
    def _cap_properties_size(cls, v: dict[str, Any]) -> dict[str, Any]:
        # Cheap byte-size guard — clients shouldn't be smuggling large
        # payloads through analytics. The JSON serialisation that pydantic
        # will run on insert would still cost the same, this just rejects
        # the obvious abuse early.
        import json

        try:
            size = len(json.dumps(v, default=str))
        except (TypeError, ValueError) as e:
            raise ValueError(f"properties is not JSON-serialisable: {e}") from e
        if size > _MAX_PROPERTY_BYTES:
            raise ValueError(
                f"properties exceeds {_MAX_PROPERTY_BYTES} bytes (got {size})"
            )
        return v


class AnalyticsBatchIn(BaseModel):
    """Batch ingest. The frontend always sends batches even of size 1
    so the wire format is uniform."""

    events: list[AnalyticsEventIn] = Field(min_length=1, max_length=_MAX_BATCH)


class AnalyticsIngestResponse(BaseModel):
    accepted: int
    stitched_user_id: UUID | None = None
    stitched_count: int = 0
