"""OS-level push delivery via FCM v1 (Android) and APNS (iOS).

This module is intentionally pluggable: when the relevant env vars are
unset, push delivery is a no-op and the in-app SSE channel keeps
working unchanged. That lets the rest of the codebase call
``dispatch_push(...)`` without branching on whether push is configured.

Configuration:
- FCM v1: requires a service-account JSON. Set ``FCM_SERVICE_ACCOUNT_JSON``
  to either a path or the raw JSON. The project ID is auto-detected.
- APNS: not implemented here yet — most projects route iOS push through
  FCM v1 too, which already works once the iOS client registers an FCM
  token. A direct-APNS path can land later without changing call-sites.

Tokens that FCM tells us are stale (404 / 410 / UNREGISTERED) are
removed from ``push_subscriptions`` so we don't keep retrying them.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from typing import Any
from uuid import UUID

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.logger import get_logger
from app.models.push_subscription import PushSubscription

log = get_logger("app.push")


# ---------------------------------------------------------------------------
# FCM access-token cache (Google service-account → OAuth bearer)
# ---------------------------------------------------------------------------


@dataclass
class _FcmCreds:
    project_id: str
    client_email: str
    private_key: str


_fcm_creds: _FcmCreds | None = None
_fcm_token: str | None = None
_fcm_token_expires_at: float = 0.0
_FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"


def _load_fcm_creds() -> _FcmCreds | None:
    """Resolve service-account JSON from ``FCM_SERVICE_ACCOUNT_JSON``.

    The env var may hold either a filesystem path or the raw JSON
    payload — both forms are common in deployment templates.
    """
    global _fcm_creds
    if _fcm_creds is not None:
        return _fcm_creds
    raw = os.getenv("FCM_SERVICE_ACCOUNT_JSON")
    if not raw:
        return None
    try:
        if raw.lstrip().startswith("{"):
            payload = json.loads(raw)
        else:
            with open(raw, "r", encoding="utf-8") as f:
                payload = json.load(f)
        _fcm_creds = _FcmCreds(
            project_id=payload["project_id"],
            client_email=payload["client_email"],
            private_key=payload["private_key"],
        )
        return _fcm_creds
    except Exception as exc:
        log.warning("FCM credentials unavailable: %s", exc)
        return None


async def _fetch_fcm_token() -> str | None:
    """Mint an OAuth access token for FCM v1 from the service account.

    Cached for ~50 minutes (tokens are valid 60). Uses ``python-jose``
    which is already a project dependency, so no new requirements.
    """
    global _fcm_token, _fcm_token_expires_at
    now = time.time()
    if _fcm_token and now < _fcm_token_expires_at - 60:
        return _fcm_token

    creds = _load_fcm_creds()
    if creds is None:
        return None

    from jose import jwt as jose_jwt

    iat = int(now)
    exp = iat + 3600
    assertion = jose_jwt.encode(
        {
            "iss": creds.client_email,
            "scope": _FCM_SCOPE,
            "aud": "https://oauth2.googleapis.com/token",
            "iat": iat,
            "exp": exp,
        },
        creds.private_key,
        algorithm="RS256",
    )
    async with httpx.AsyncClient(timeout=15.0) as client:
        resp = await client.post(
            "https://oauth2.googleapis.com/token",
            data={
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": assertion,
            },
        )
    if resp.status_code != 200:
        log.warning("FCM oauth failed (%s): %s", resp.status_code, resp.text[:200])
        return None
    body = resp.json()
    _fcm_token = body.get("access_token")
    _fcm_token_expires_at = now + int(body.get("expires_in", 3600))
    return _fcm_token


# ---------------------------------------------------------------------------
# Public dispatcher
# ---------------------------------------------------------------------------


def push_enabled() -> bool:
    return _load_fcm_creds() is not None


async def dispatch_push(
    db: AsyncSession,
    *,
    user_id: UUID,
    title: str,
    body: str,
    data: dict[str, Any] | None = None,
) -> None:
    """Send a push to every device subscribed for [user_id].

    Best-effort: errors per device are logged and stale tokens removed,
    but the caller's transaction is never rolled back.
    """
    if not push_enabled():
        return

    result = await db.execute(
        select(PushSubscription).where(PushSubscription.user_id == user_id)
    )
    subs = result.scalars().all()
    if not subs:
        return

    creds = _load_fcm_creds()
    if creds is None:
        return
    access_token = await _fetch_fcm_token()
    if access_token is None:
        return

    url = (
        f"https://fcm.googleapis.com/v1/projects/{creds.project_id}/messages:send"
    )
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json; charset=UTF-8",
    }

    stale: list[PushSubscription] = []
    async with httpx.AsyncClient(timeout=15.0) as client:
        for sub in subs:
            if sub.platform not in ("fcm", "apns"):
                # Web push uses VAPID, not FCM v1 — handle separately if/when added.
                continue
            payload = {
                "message": {
                    "token": sub.token,
                    "notification": {"title": title, "body": body},
                    "data": {k: str(v) for k, v in (data or {}).items()},
                }
            }
            try:
                resp = await client.post(url, headers=headers, json=payload)
            except httpx.HTTPError as exc:
                log.warning("FCM transport error for %s: %s", sub.id, exc)
                continue
            if resp.status_code in (404, 410):
                stale.append(sub)
                continue
            if resp.status_code >= 400:
                # FCM v1 returns 400 + UNREGISTERED for stale Android tokens.
                try:
                    err = resp.json().get("error", {})
                except Exception:
                    err = {}
                code = (err.get("status") or "").upper()
                if code in {"UNREGISTERED", "NOT_FOUND", "INVALID_ARGUMENT"}:
                    stale.append(sub)
                else:
                    log.warning(
                        "FCM send failed (%s) for %s: %s",
                        resp.status_code, sub.id, resp.text[:200],
                    )

    for sub in stale:
        await db.delete(sub)
    if stale:
        await db.flush()
