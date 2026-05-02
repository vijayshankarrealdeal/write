"""Public early-tester signup — backs the landing page at `/land`.

No authentication: anyone with the link can leave their email. We
dedupe on email (case-insensitive) so re-submitting the same address
returns the app link without raising on the unique constraint.
"""
from __future__ import annotations

import os
import re

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models.early_tester import EarlyTester

router = APIRouter(prefix="/api/early-testers", tags=["early-testers"])


# Liberal RFC-5321-ish regex — full RFC compliance is rarely worth the
# false positives in a marketing form.
_EMAIL_RE = re.compile(
    r"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"
)


def _app_download_url() -> str:
    """Where to send signups. Configurable via APP_DOWNLOAD_URL env var
    so the landing page can point at TestFlight, an internal-test Play
    Store track, or a direct APK without a code change."""
    return os.getenv(
        "APP_DOWNLOAD_URL",
        "https://play.google.com/store/apps/details?id=com.inkspacex.app",
    )


@router.post("/signup", status_code=201)
async def signup(
    payload: dict,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    raw_email = (payload.get("email") or "").strip().lower()
    if not raw_email or len(raw_email) > 320 or not _EMAIL_RE.match(raw_email):
        raise HTTPException(status_code=400, detail="Please enter a valid email.")

    source = (payload.get("source") or "land")[:64]
    user_agent = (request.headers.get("user-agent") or "")[:512]
    # Trust X-Forwarded-For only when set by our own proxy (Caddy).
    fwd = request.headers.get("x-forwarded-for")
    ip = (fwd.split(",")[0].strip() if fwd else (request.client.host if request.client else None))
    if ip:
        ip = ip[:64]

    existing = (
        await db.execute(
            select(EarlyTester).where(EarlyTester.email == raw_email)
        )
    ).scalar_one_or_none()

    if existing is None:
        record = EarlyTester(
            email=raw_email,
            source=source,
            user_agent=user_agent or None,
            ip=ip,
        )
        db.add(record)
        await db.commit()
        already = False
    else:
        already = True

    return {
        "ok": True,
        "already_signed_up": already,
        "app_url": _app_download_url(),
    }
