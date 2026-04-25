import os
import traceback
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from app.config import settings
from app.database import async_session, engine
from app.logger import get_logger, setup_logging, start_drain, stop_drain
from app.models import Base
from app.models.analytics import CrashReport
from app.ai.router import router as ai_router
from app.middleware import RequestLoggingMiddleware
from app.routers import admin, auth, bookshelves, comments, crashes, feed, highlights, logs, reading, upload, users, writings

setup_logging()
log = get_logger("app.main")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Create tables on startup (use Alembic migrations in production)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    await start_drain()
    log.info("InkSpaceX API started")
    yield
    log.info("InkSpaceX API shutting down")
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
app.include_router(highlights.router)
app.include_router(bookshelves.router)
app.include_router(reading.router)
app.include_router(upload.router)
app.include_router(ai_router)
app.include_router(admin.router)
app.include_router(crashes.router)
app.include_router(logs.router)

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
@app.api_route(
    "/api/{rest_of_path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    include_in_schema=False,
)
async def api_not_found(rest_of_path: str):
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
