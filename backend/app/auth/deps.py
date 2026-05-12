import asyncio
import logging
from uuid import UUID

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.jwt import decode_token
from app.database import async_session, get_db
from app.geo import resolve_country_code
from app.models.user import User

security = HTTPBearer()
optional_security = HTTPBearer(auto_error=False)

log = logging.getLogger("app.auth.deps")


async def _resolve_country_in_background(user_id: UUID, request: Request) -> None:
    """Resolve the calling user's country and write it to `users.country_code`.

    Fired as a fire-and-forget task from `get_current_user` so the
    Caddy-header read (or, as fallback, the ip-api round-trip) doesn't
    hold auth latency. Idempotent: if the column was filled by a
    concurrent request first, we skip the write.

    Errors are swallowed — geo resolution is best-effort observability
    that powers payment-provider routing later; failing here must not
    surface to the user.
    """
    try:
        code = await resolve_country_code(request)
        if code is None:
            return
        async with async_session() as session:
            row = await session.execute(
                select(User).where(User.id == user_id)
            )
            user = row.scalar_one_or_none()
            if user is None or user.country_code is not None:
                return
            user.country_code = code
            await session.commit()
    except Exception as exc:  # pragma: no cover — defensive only
        log.debug("country resolution failed for user %s: %s", user_id, exc)


async def get_current_user(
    request: Request,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: AsyncSession = Depends(get_db),
) -> User:
    payload = decode_token(credentials.credentials)
    if payload is None or payload.get("type") != "access":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
        )

    user_id = UUID(payload["sub"])
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()

    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User not found",
        )

    # First-request country resolution. Fire-and-forget; the column is
    # nullable so endpoints that read it must already tolerate `None`.
    # The task short-circuits on the not-null check inside its own
    # session, so a flurry of in-flight requests from a brand-new user
    # fan out to at most one persisted write.
    if user.country_code is None:
        asyncio.create_task(
            _resolve_country_in_background(user.id, request)
        )

    return user


async def get_optional_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(optional_security),
    db: AsyncSession = Depends(get_db),
) -> User | None:
    """Auth dep for endpoints that accept anonymous traffic but want to
    auto-attach a user when a valid token is present. Used by analytics
    so pre-login events still flow."""
    if credentials is None:
        return None
    payload = decode_token(credentials.credentials)
    if payload is None or payload.get("type") != "access":
        return None
    try:
        user_id = UUID(payload["sub"])
    except (KeyError, ValueError):
        return None
    result = await db.execute(select(User).where(User.id == user_id))
    return result.scalar_one_or_none()
