"""User-behaviour analytics ingest.

The frontend's `AnalyticsService` posts batches here. Anonymous events
are accepted (events fire before login); when a request carries a valid
JWT the resulting rows attach `user_id`, AND we backfill any prior
anonymous rows that share the same `client_id` — that's how a user's
journey from "landing → login → first post" stays queryable as a
single sequence keyed on `user_id`.

See `lib/services/analytics_service.dart` for the producer side and
`PLAN.md` for the documented event taxonomy.
"""
from __future__ import annotations

from collections import defaultdict
from typing import Any

from fastapi import APIRouter, Depends, Request
from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_optional_user
from app.database import get_db
from app.models.analytics import AnalyticsEvent
from app.models.user import User
from app.schemas.analytics import AnalyticsBatchIn, AnalyticsIngestResponse


router = APIRouter(prefix="/api/analytics", tags=["analytics"])

# Cap on body bytes — Pydantic already caps per-event properties at 4 KiB
# and batches at 100, but a malicious client could still send fat
# `properties` 100 times. 256 KiB is plenty of headroom for legitimate
# batches and small enough to keep memory bounded under abuse.
_MAX_BODY_BYTES = 256 * 1024


def _client_ip(request: Request) -> str | None:
    # Caddy → uvicorn already populates request.client.host with the real
    # IP because we run uvicorn with --proxy-headers --forwarded-allow-ips=*.
    if request.client is None:
        return None
    return request.client.host


@router.post("/events", response_model=AnalyticsIngestResponse)
async def ingest_events(
    batch: AnalyticsBatchIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
    user: User | None = Depends(get_optional_user),
):
    """Insert a batch of events.

    Returns the number accepted; if the batch was authenticated, also
    reports how many prior anonymous rows were stitched onto the user.
    """
    # Body-size guard — content-length is the cheapest check; we don't
    # buffer the request body ourselves, so this is a soft cap (Pydantic
    # has already parsed by the time we get here). Still useful as a
    # signal the caller is misbehaving so we can reject loudly.
    cl = request.headers.get("content-length")
    if cl and cl.isdigit() and int(cl) > _MAX_BODY_BYTES:
        # Truncate before insert rather than 413 — losing analytics is
        # always preferable to surfacing an error users would see.
        batch.events = batch.events[:1]

    ua = (request.headers.get("user-agent") or "")[:500]
    ip = _client_ip(request)
    user_id = user.id if user is not None else None

    rows = [
        AnalyticsEvent(
            user_id=user_id,
            client_id=ev.client_id,
            session_id=ev.session_id,
            event_name=ev.event_name,
            screen=ev.screen,
            action=ev.action,
            entity_type=ev.entity_type,
            entity_id=ev.entity_id,
            source_screen=ev.source_screen,
            duration_ms=ev.duration_ms,
            properties=ev.properties or {},
            client_ts=ev.client_ts,
            user_agent=ua or None,
            ip=ip,
        )
        for ev in batch.events
    ]
    db.add_all(rows)

    stitched_count = 0
    stitched_user_id = None
    if user_id is not None:
        # Stitch any prior anonymous events from this client onto the
        # now-known user. Idempotent: after the first auth'd batch the
        # backfill matches zero rows.
        client_ids: set[str] = {ev.client_id for ev in batch.events}
        result = await db.execute(
            update(AnalyticsEvent)
            .where(
                AnalyticsEvent.user_id.is_(None),
                AnalyticsEvent.client_id.in_(client_ids),
            )
            .values(user_id=user_id)
        )
        stitched_count = result.rowcount or 0
        stitched_user_id = user_id

    await db.commit()

    return AnalyticsIngestResponse(
        accepted=len(rows),
        stitched_user_id=stitched_user_id,
        stitched_count=stitched_count,
    )
