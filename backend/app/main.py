import asyncio
import os
import traceback
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import text
from starlette.routing import Match

from app.config import settings
from app.database import async_session, engine
from app.logger import get_logger, setup_logging, start_drain, stop_drain
from app.models import Base
from app.models.analytics import CrashReport
from app.ai.router import router as ai_router
from app.middleware import RequestLoggingMiddleware
from app.offline.router import router as offline_router
from app.realtime import hub as realtime_hub
from app import spellcheck as spellcheck_engine
from app.routers import (
    admin,
    analytics,
    auth,
    bookmarks,
    bookshelves,
    chat,
    comments,
    crashes,
    feed,
    highlights,
    logs,
    notifications,
    reading,
    realtime,
    reports,
    spellcheck,
    upload,
    users,
    writings,
)

setup_logging()
log = get_logger("app.main")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Create tables on startup (use Alembic migrations in production)
    async with engine.begin() as conn:
        # pgvector must exist before `create_all` tries to instantiate the
        # `embedding VECTOR(...)` column on `feed_items`. Idempotent.
        await conn.execute(text("CREATE EXTENSION IF NOT EXISTS vector"))
        await conn.run_sync(Base.metadata.create_all)
        # One-shot widen: existing DBs created before BigInteger have INTEGER here,
        # which can't hold Flutter's unsigned ARGB color values. Idempotent.
        current = await conn.execute(text(
            "SELECT data_type FROM information_schema.columns "
            "WHERE table_name='sections' AND column_name='section_color'"
        ))
        if current.scalar() == 'integer':
            await conn.execute(text(
                "ALTER TABLE sections ALTER COLUMN section_color TYPE BIGINT"
            ))
        # Image metadata sidecar columns. Idempotent — IF NOT EXISTS lets
        # existing DBs pick up the new pipeline without an external migration.
        for table, col in (
            ("users", "photo_meta"),
            ("bookshelves", "cover_image_meta"),
            ("writings", "cover_image_meta"),
            ("feed_items", "image_meta"),
            ("comments", "author_photo_meta"),
        ):
            await conn.execute(text(
                f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS {col} JSONB"
            ))
        # Phase 3 (P2): paragraph-precise resume anchor columns on
        # reading_progress. Idempotent for dev DBs that bypass Alembic.
        await conn.execute(text(
            "ALTER TABLE reading_progress "
            "ADD COLUMN IF NOT EXISTS last_section_id VARCHAR(64)"
        ))
        await conn.execute(text(
            "ALTER TABLE reading_progress "
            "ADD COLUMN IF NOT EXISTS last_anchor JSONB"
        ))
        # Phase 2 (P2): facet count cache table. Idempotent for dev DBs
        # that bypass Alembic. Populated by the nightly script in
        # `backend/scripts/refresh_feed_facets.py`.
        await conn.execute(text(
            """
            CREATE TABLE IF NOT EXISTS feed_facets (
                kind VARCHAR(16) NOT NULL,
                value VARCHAR(64) NOT NULL,
                count INTEGER NOT NULL,
                refreshed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                PRIMARY KEY (kind, value)
            )
            """
        ))
        await conn.execute(text(
            "CREATE INDEX IF NOT EXISTS ix_feed_facets_kind_count "
            "ON feed_facets (kind, count DESC)"
        ))
    await start_drain()
    await realtime_hub.start()
    # Warm the spell-check dictionary so the first /api/spellcheck/check
    # doesn't pay ~200ms of file I/O. Off the event loop — file is ~2MB.
    asyncio.get_running_loop().run_in_executor(None, spellcheck_engine.warm)
    log.info("InkSpaceX API started")
    yield
    log.info("InkSpaceX API shutting down")
    await realtime_hub.stop()
    await stop_drain()
    await engine.dispose()


app = FastAPI(
    title="InkSpaceX API",
    version="1.0.0",
    lifespan=lifespan,
    # redirect_slashes is safe again now that uvicorn is started with
    # --proxy-headers + --forwarded-allow-ips=*, so trailing-slash redirects
    # respect X-Forwarded-Proto and stay on https://.
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins.split(","),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Register routers
app.include_router(auth.router)
app.include_router(users.router)
app.include_router(writings.router)
app.include_router(feed.router)
app.include_router(comments.router)
app.include_router(chat.router)
app.include_router(highlights.router)
app.include_router(bookshelves.router)
app.include_router(reading.router)
app.include_router(bookmarks.router)
app.include_router(upload.router)
app.include_router(ai_router)
app.include_router(offline_router)
app.include_router(admin.router)
app.include_router(crashes.router)
app.include_router(logs.router)
app.include_router(notifications.router)
app.include_router(realtime.router)
app.include_router(analytics.router)
app.include_router(spellcheck.router)
app.include_router(reports.router)

# Request logging middleware
app.add_middleware(RequestLoggingMiddleware)


# Global exception handler — log full stack trace to crash_reports, return friendly message
@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    stack_trace = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
    error_type = type(exc).__name__
    error_message = str(exc) or error_type

    log.error(
        "Unhandled %s on %s %s: %s",
        error_type, request.method, request.url.path, error_message,
        exc_info=(type(exc), exc, exc.__traceback__),
    )

    # Persist the crash — never let logging failures break the response
    try:
        async with async_session() as session:
            crash = CrashReport(
                error_type=error_type,
                error_message=error_message,
                stack_trace=stack_trace,
                page=str(request.url.path),
                platform="backend",
            )
            session.add(crash)
            await session.commit()
    except Exception:
        pass

    # Friendly message to the user — hide internals
    return JSONResponse(
        status_code=500,
        content={"detail": "Something went wrong. Our team has been notified."},
    )


@app.get("/api/health")
async def health():
    return {"status": "ok"}


# Catch-all for unknown /api/* paths. Without this, an unmatched /api/... would
# fall through to the admin SPA below and return index.html — which the Flutter
# client would then try to JSON.parse and crash on. Always return JSON 404.
#
# Before 404'ing, we replicate FastAPI's built-in redirect_slashes behavior:
# this catch-all is registered as a real route, so it short-circuits the
# framework's automatic /foo ↔ /foo/ redirect. We do that check ourselves.
@app.api_route(
    "/api/{rest_of_path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    include_in_schema=False,
)
async def api_not_found(request: Request, rest_of_path: str):
    current_path = request.url.path
    alt_path = current_path[:-1] if current_path.endswith("/") else current_path + "/"
    alt_scope = {**request.scope, "path": alt_path}
    for route in app.routes:
        if getattr(route, "endpoint", None) is api_not_found:
            continue
        if not hasattr(route, "matches"):
            continue
        match, _ = route.matches(alt_scope)
        if match == Match.FULL:
            return RedirectResponse(url=str(request.url.replace(path=alt_path)), status_code=307)
    return JSONResponse(
        status_code=404,
        content={"detail": f"API endpoint not found: /api/{rest_of_path}"},
    )


# Serve admin dashboard static files if the build exists.
# Use a catch-all route so client-side routes (e.g. /admin/crashes) fall back to index.html.
_admin_dist = Path(__file__).resolve().parent.parent / "admin-dist"
if _admin_dist.is_dir():
    _admin_assets = _admin_dist / "assets"
    if _admin_assets.is_dir():
        app.mount("/admin/assets", StaticFiles(directory=str(_admin_assets)), name="admin-assets")

    @app.get("/admin")
    @app.get("/admin/{full_path:path}")
    async def admin_spa(full_path: str = ""):
        # Serve specific static files directly (e.g. vite.svg, favicon)
        if full_path and not full_path.startswith("assets/"):
            candidate = _admin_dist / full_path
            if candidate.is_file():
                return FileResponse(candidate)
        # SPA fallback — let React Router handle client-side routes
        return FileResponse(_admin_dist / "index.html")
