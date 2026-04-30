import asyncio
import urllib.parse
from datetime import UTC, datetime, timedelta

import httpx
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token
from jose import JWTError, jwt as jose_jwt

from app.config import settings


GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"

# Native clients can't follow the OAuth redirect back into the app without a
# custom URL scheme. Instead, they pass a one-time `session_id` to /start;
# /callback parks the freshly-minted JWT pair here against that id, and the
# client polls /session/{id} until they appear. 5-min TTL keeps the table
# from accumulating dead entries — long enough for a slow user, short enough
# that any leaked id is useless before they could use it.
_PENDING_TOKEN_TTL = timedelta(minutes=5)
_pending_tokens: dict[str, tuple[str, str, datetime]] = {}
_pending_lock = asyncio.Lock()


async def store_pending_tokens(
    session_id: str, access_token: str, refresh_token: str
) -> None:
    expires_at = datetime.now(UTC) + _PENDING_TOKEN_TTL
    async with _pending_lock:
        _prune_pending_tokens()
        _pending_tokens[session_id] = (access_token, refresh_token, expires_at)


async def pop_pending_tokens(session_id: str) -> tuple[str, str] | None:
    async with _pending_lock:
        _prune_pending_tokens()
        entry = _pending_tokens.pop(session_id, None)
    if entry is None:
        return None
    access, refresh, _ = entry
    return access, refresh


def _prune_pending_tokens() -> None:
    now = datetime.now(UTC)
    expired = [sid for sid, (_, _, exp) in _pending_tokens.items() if exp < now]
    for sid in expired:
        _pending_tokens.pop(sid, None)


async def verify_google_id_token(token: str) -> dict | None:
    """Verify a Google ID token and return the user info payload."""
    try:
        idinfo = id_token.verify_oauth2_token(
            token,
            google_requests.Request(),
            settings.google_client_id,
        )

        if idinfo["iss"] not in ("accounts.google.com", "https://accounts.google.com"):
            return None

        return {
            "email": idinfo["email"],
            "name": idinfo.get("name"),
            "photo_url": idinfo.get("picture"),
        }
    except ValueError:
        return None


def safe_callback_uri(callback_uri: str | None) -> str | None:
    """Restrict the post-OAuth redirect to URIs we trust, so this callback
    cannot be repurposed as an open redirect.

    Allowed:
      - Native custom scheme: `inkspacex://` (any path/host).
      - Any path on a CORS-allowed frontend origin (typically `/auth.html`,
        the postMessage bridge served from the SPA).
    """
    if not callback_uri:
        return None
    try:
        parsed = urllib.parse.urlparse(callback_uri)
    except ValueError:
        return None
    if not parsed.scheme:
        return None

    if parsed.scheme == "inkspacex":
        return callback_uri

    for origin in _allowed_frontend_origins():
        origin_parsed = urllib.parse.urlparse(origin)
        if (
            parsed.scheme == origin_parsed.scheme
            and parsed.netloc == origin_parsed.netloc
        ):
            return callback_uri
    return None


def _allowed_frontend_origins() -> list[str]:
    origins: list[str] = []
    if settings.frontend_origin:
        origins.append(settings.frontend_origin.strip())
    for o in settings.cors_origins.split(","):
        o = o.strip()
        if o and o not in origins:
            origins.append(o)
    return origins


def create_oauth_state(
    *, callback_uri: str | None = None, session_id: str | None = None
) -> str:
    """Sign a short-lived state token. Web carries `callback_uri` (the SPA URL
    we redirect to with tokens in the fragment); native carries `session_id`
    (the polling key)."""
    expire = datetime.now(UTC) + timedelta(minutes=10)
    payload: dict = {"exp": expire, "type": "oauth_state"}
    if callback_uri:
        payload["callback_uri"] = callback_uri
    if session_id:
        payload["session_id"] = session_id
    return jose_jwt.encode(
        payload,
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )


def decode_oauth_state(state: str) -> dict | None:
    try:
        payload = jose_jwt.decode(
            state,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
        )
        if payload.get("type") != "oauth_state":
            return None
        return payload
    except JWTError:
        return None


def google_auth_url(state: str, redirect_uri: str) -> str:
    params = {
        "client_id": settings.google_client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": "openid email profile",
        "state": state,
        "access_type": "online",
        "prompt": "select_account",
        "include_granted_scopes": "true",
    }
    return f"{GOOGLE_AUTH_URL}?{urllib.parse.urlencode(params)}"


async def exchange_code_for_user_info(code: str, redirect_uri: str) -> dict | None:
    """Exchange an OAuth authorization code for an ID token, then verify it."""
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                GOOGLE_TOKEN_URL,
                data={
                    "code": code,
                    "client_id": settings.google_client_id,
                    "client_secret": settings.google_client_secret,
                    "redirect_uri": redirect_uri,
                    "grant_type": "authorization_code",
                },
            )
        if resp.status_code != 200:
            return None
        id_tok = resp.json().get("id_token")
        if not id_tok:
            return None
        return await verify_google_id_token(id_tok)
    except (httpx.HTTPError, ValueError):
        return None
