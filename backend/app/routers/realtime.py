"""SSE endpoints for live notifications + comments.

Auth: SSE is plain HTTP, so the standard ``Authorization: Bearer …``
header works. EventSource in browsers can't set headers, but the Flutter
client uses ``http.Client`` which can — so we accept the header AND a
``token`` query-param fallback (kept for the rare browser case).
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, Request, status
from fastapi.responses import StreamingResponse
from sqlalchemy import select

from app.auth.jwt import decode_token
from app.database import async_session
from app.logger import get_logger
from app.models.user import User
from app.models.writing import Writing
from app.realtime import event_stream

log = get_logger("app.routers.realtime")

router = APIRouter(prefix="/api/stream", tags=["realtime"])

_SSE_HEADERS = {
    "Cache-Control": "no-cache, no-transform",
    "X-Accel-Buffering": "no",  # disable buffering on nginx/Caddy
    "Connection": "keep-alive",
}


def _extract_token(request: Request, fallback_token: str | None) -> str | None:
    auth = request.headers.get("authorization") or request.headers.get("Authorization")
    if auth and auth.lower().startswith("bearer "):
        return auth.split(" ", 1)[1].strip()
    return fallback_token


async def _resolve_user(token: str | None) -> User | None:
    if not token:
        return None
    payload = decode_token(token)
    if payload is None or payload.get("type") != "access":
        return None
    try:
        user_id = UUID(payload["sub"])
    except (KeyError, ValueError):
        return None
    async with async_session() as session:
        result = await session.execute(select(User).where(User.id == user_id))
        return result.scalar_one_or_none()


@router.get("/notifications")
async def notifications_stream(
    request: Request,
    token: str | None = Query(default=None),
):
    user = await _resolve_user(_extract_token(request, token))
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing token",
        )
    channel = f"user:{user.id}"
    return StreamingResponse(
        event_stream(channel),
        media_type="text/event-stream",
        headers=_SSE_HEADERS,
    )


@router.get("/feed/{item_id}/comments")
async def comments_stream(
    item_id: UUID,
    request: Request,
    token: str | None = Query(default=None),
):
    user = await _resolve_user(_extract_token(request, token))
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing token",
        )
    channel = f"feed:{item_id}"
    return StreamingResponse(
        event_stream(channel),
        media_type="text/event-stream",
        headers=_SSE_HEADERS,
    )


@router.get("/dictionary")
async def dictionary_stream(
    request: Request,
    token: str | None = Query(default=None),
):
    """Live dictionary version updates for every authenticated client.

    Payloads: ``{"type":"dictionary.updated","version":N}``. The client
    reacts by GET'ing ``/api/dictionary/snapshot?since=<cached>`` to
    pull the delta. The wire frame is a single integer — no user prose
    crosses this channel.
    """
    user = await _resolve_user(_extract_token(request, token))
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing token",
        )
    return StreamingResponse(
        event_stream("dictionary"),
        media_type="text/event-stream",
        headers=_SSE_HEADERS,
    )


@router.get("/writings/{writing_id}")
async def writing_stream(
    writing_id: UUID,
    request: Request,
    token: str | None = Query(default=None),
):
    user = await _resolve_user(_extract_token(request, token))
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing token",
        )
    async with async_session() as session:
        result = await session.execute(
            select(Writing).where(
                Writing.id == writing_id, Writing.user_id == user.id
            )
        )
        if result.scalar_one_or_none() is None:
            raise HTTPException(status_code=404, detail="Writing not found")
    channel = f"writing:{writing_id}"
    return StreamingResponse(
        event_stream(channel),
        media_type="text/event-stream",
        headers=_SSE_HEADERS,
    )
