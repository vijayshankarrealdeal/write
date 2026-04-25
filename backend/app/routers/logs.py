"""Public log-ingest endpoint for client apps (Flutter, web, etc.).

Accepts batched log entries. No auth required — clients post their own
logs so we can correlate frontend errors with backend state.
"""

from fastapi import APIRouter, Request
from sqlalchemy.ext.asyncio import AsyncSession  # noqa: F401 — kept for type hints if needed later

from app.logger import log_event

router = APIRouter(prefix="/api/logs", tags=["logs"])

_ALLOWED_LEVELS = {"debug", "info", "warn", "error"}


def _coerce_level(value: object) -> str:
    level = str(value or "info").lower()
    if level == "debug":
        return "info"  # AppLog schema uses 3 buckets
    if level not in _ALLOWED_LEVELS:
        return "info"
    return level


@router.post("")
async def ingest_logs(payload: dict, request: Request):
    """Accept either one log entry or a batch.

    Single:    {level, source, logger, message, details, ...}
    Batched:   {logs: [ {...}, {...} ]}
    """

    entries = payload.get("logs") if isinstance(payload.get("logs"), list) else [payload]
    accepted = 0
    ua = request.headers.get("user-agent", "")[:500]

    for entry in entries:
        if not isinstance(entry, dict):
            continue
        message = entry.get("message")
        if not message:
            continue

        details = entry.get("details")
        if details is not None and not isinstance(details, str):
            try:
                import json

                details = json.dumps(details)
            except Exception:
                details = str(details)

        log_event(
            level=_coerce_level(entry.get("level")),
            source=str(entry.get("source") or "frontend")[:20],
            logger=(str(entry.get("logger"))[:200] if entry.get("logger") else None),
            message=str(message),
            details=details if details else (ua or None),
            user_id=entry.get("user_id"),
            request_path=entry.get("request_path"),
            request_method=entry.get("request_method"),
            status_code=entry.get("status_code"),
            duration_ms=entry.get("duration_ms"),
        )
        accepted += 1

    return {"status": "ok", "accepted": accepted}
