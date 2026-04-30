import urllib.parse
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import RedirectResponse
from passlib.context import CryptContext
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.auth.jwt import create_access_token, create_refresh_token, decode_token
from app.auth.oauth import (
    create_oauth_state,
    decode_oauth_state,
    exchange_code_for_user_info,
    google_auth_url,
    pop_pending_tokens,
    safe_callback_uri,
    store_pending_tokens,
    verify_google_id_token,
)
from app.config import settings
from app.database import get_db
from app.models.user import User
from app.schemas.auth import (
    GoogleAuthRequest,
    LoginRequest,
    RefreshRequest,
    RegisterRequest,
    ResetPasswordRequest,
    TokenResponse,
)
from app.schemas.user import UserResponse

router = APIRouter(prefix="/api/auth", tags=["auth"])
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


@router.post("/register", response_model=TokenResponse)
async def register(req: RegisterRequest, db: AsyncSession = Depends(get_db)):
    # Check if user already exists
    result = await db.execute(select(User).where(User.email == req.email))
    if result.scalar_one_or_none():
        raise HTTPException(status_code=400, detail="Email already registered")

    user = User(
        email=req.email,
        name=req.name,
        password_hash=pwd_context.hash(req.password),
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)

    return TokenResponse(
        access_token=create_access_token(user.id),
        refresh_token=create_refresh_token(user.id),
    )


@router.post("/login", response_model=TokenResponse)
async def login(req: LoginRequest, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.email == req.email))
    user = result.scalar_one_or_none()

    if not user or not user.password_hash or not pwd_context.verify(req.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid email or password")

    return TokenResponse(
        access_token=create_access_token(user.id),
        refresh_token=create_refresh_token(user.id),
    )


@router.post("/google", response_model=TokenResponse)
async def google_auth(req: GoogleAuthRequest, db: AsyncSession = Depends(get_db)):
    user_info = await verify_google_id_token(req.id_token)
    if user_info is None:
        raise HTTPException(status_code=401, detail="Invalid Google token")

    # Find or create user
    result = await db.execute(select(User).where(User.email == user_info["email"]))
    user = result.scalar_one_or_none()

    if user is None:
        user = User(
            email=user_info["email"],
            name=user_info.get("name"),
            photo_url=user_info.get("photo_url"),
        )
        db.add(user)
        await db.commit()
        await db.refresh(user)
    else:
        # Update name/photo if changed
        if user_info.get("name") and not user.name:
            user.name = user_info["name"]
        if user_info.get("photo_url") and not user.photo_url:
            user.photo_url = user_info["photo_url"]
        await db.commit()

    return TokenResponse(
        access_token=create_access_token(user.id),
        refresh_token=create_refresh_token(user.id),
    )


@router.get("/google/start")
async def google_start(
    callback_uri: str | None = None,
    session_id: str | None = None,
):
    """Browser-redirect entry point for Google OAuth.

    Web pass `callback_uri` (a URL on the SPA origin) — we redirect there
    with `#access_token=...&refresh_token=...` after OAuth completes.
    Native pass `session_id` — we park the tokens against that id and the
    app polls `/google/session/{id}`. Native callers don't need a custom URL
    scheme; the system browser stays on a backend "you can return to the app"
    page when polling completes."""
    if not settings.google_client_secret or not settings.google_oauth_redirect_uri:
        raise HTTPException(status_code=503, detail="Google OAuth not configured")

    safe_cb = safe_callback_uri(callback_uri)
    if safe_cb is None and not session_id:
        raise HTTPException(
            status_code=400, detail="Missing or invalid callback_uri/session_id"
        )

    state = create_oauth_state(callback_uri=safe_cb, session_id=session_id)
    url = google_auth_url(state, settings.google_oauth_redirect_uri)
    return RedirectResponse(url=url, status_code=302)


@router.get("/google/callback")
async def google_callback(
    code: str | None = None,
    state: str | None = None,
    error: str | None = None,
    db: AsyncSession = Depends(get_db),
):
    """Google redirects here with `code` and `state`. We decode the state to
    learn whether this is a web flow (token-fragment redirect) or a native
    flow (token stash for polling), then mint our JWTs and dispatch."""
    payload = decode_oauth_state(state) if state else None
    if payload is None:
        raise HTTPException(status_code=400, detail="Invalid or expired state")

    callback_uri = payload.get("callback_uri")
    session_id = payload.get("session_id")

    if error:
        return _oauth_error_response(error, callback_uri, session_id)
    if not code:
        raise HTTPException(status_code=400, detail="Missing authorization code")

    user_info = await exchange_code_for_user_info(
        code, settings.google_oauth_redirect_uri
    )
    if user_info is None:
        return _oauth_error_response("verification_failed", callback_uri, session_id)

    result = await db.execute(select(User).where(User.email == user_info["email"]))
    user = result.scalar_one_or_none()

    if user is None:
        user = User(
            email=user_info["email"],
            name=user_info.get("name"),
            photo_url=user_info.get("photo_url"),
        )
        db.add(user)
        await db.commit()
        await db.refresh(user)
    else:
        if user_info.get("name") and not user.name:
            user.name = user_info["name"]
        if user_info.get("photo_url") and not user.photo_url:
            user.photo_url = user_info["photo_url"]
        await db.commit()

    access = create_access_token(user.id)
    refresh = create_refresh_token(user.id)

    if session_id:
        await store_pending_tokens(session_id, access, refresh)
        return _oauth_done_page("Signed in. Return to the app to continue.")

    fragment = urllib.parse.urlencode(
        {"access_token": access, "refresh_token": refresh}
    )
    sep = "&" if "#" in callback_uri else "#"
    return RedirectResponse(url=f"{callback_uri}{sep}{fragment}", status_code=302)


@router.get("/google/session/{session_id}", response_model=TokenResponse)
async def google_session_poll(session_id: str):
    """Native clients poll this after opening `/google/start` in the system
    browser. Returns 404 until the OAuth round-trip completes, then 200 with
    tokens — and clears the entry, making the session id one-shot."""
    tokens = await pop_pending_tokens(session_id)
    if tokens is None:
        raise HTTPException(status_code=404, detail="Pending or expired")
    access, refresh = tokens
    return TokenResponse(access_token=access, refresh_token=refresh)


def _oauth_error_response(
    error: str, callback_uri: str | None, session_id: str | None
):
    """Surface an OAuth failure to whichever flow initiated it: tokens
    fragment for web, the polling endpoint's 404 for native (the error is
    only visible as a continued 404 there, which the client times out on)."""
    if callback_uri:
        sep = "&" if "#" in callback_uri else "#"
        return RedirectResponse(
            url=f"{callback_uri}{sep}google_error={urllib.parse.quote(error)}",
            status_code=302,
        )
    return _oauth_done_page(f"Sign-in failed: {error}. Close this window and try again.")


def _oauth_done_page(message: str):
    """Tiny static HTML response for the system browser after a native flow."""
    from fastapi.responses import HTMLResponse

    safe = (
        message.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    )
    html = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>InkSpaceX</title>
<style>
body{{margin:0;background:#000;color:#fff;font-family:-apple-system,BlinkMacSystemFont,sans-serif;
display:flex;align-items:center;justify-content:center;height:100vh;text-align:center;padding:24px}}
p{{max-width:24rem;line-height:1.5;opacity:.85}}
</style></head>
<body><p>{safe}</p></body></html>"""
    return HTMLResponse(content=html)


@router.post("/refresh", response_model=TokenResponse)
async def refresh_token(req: RefreshRequest, db: AsyncSession = Depends(get_db)):
    payload = decode_token(req.refresh_token)
    if payload is None or payload.get("type") != "refresh":
        raise HTTPException(status_code=401, detail="Invalid refresh token")

    user_id = UUID(payload["sub"])
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()

    if user is None:
        raise HTTPException(status_code=401, detail="User not found")

    return TokenResponse(
        access_token=create_access_token(user.id),
        refresh_token=create_refresh_token(user.id),
    )


@router.post("/reset-password")
async def reset_password(req: ResetPasswordRequest, db: AsyncSession = Depends(get_db)):
    # In production, send an email with a reset link.
    # For now, just verify the user exists.
    result = await db.execute(select(User).where(User.email == req.email))
    # Always return success to avoid email enumeration
    return {"message": "If that email exists, a reset link has been sent."}


@router.get("/me", response_model=UserResponse)
async def get_me(user: User = Depends(get_current_user)):
    return user
