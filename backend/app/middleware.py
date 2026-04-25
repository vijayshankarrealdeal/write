"""Request logging middleware — captures every request as an AppLog entry."""

import time

from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint
from starlette.requests import Request
from starlette.responses import Response

from app.logger import get_logger, log_event

# Don't persist admin-dashboard traffic or health checks to the DB — they spam
# the logs view and aren't useful for debugging end-user flows. They still
# appear on stdout so operators can see them live.
_DB_SKIP_PREFIXES = (
    "/api/health",
    "/api/admin",  # all admin-dashboard API calls
    "/admin",      # admin dashboard static assets
    "/api/logs",   # log-ingest endpoint — must never recurse
)

_log = get_logger("app.http")


class RequestLoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: RequestResponseEndpoint) -> Response:
        start = time.perf_counter()
        status_code = 500
        error_detail = None

        try:
            response = await call_next(request)
            status_code = response.status_code
            return response
        except Exception as exc:
            error_detail = str(exc)
            raise
        finally:
            duration_ms = int((time.perf_counter() - start) * 1000)
            path = request.url.path

            level = "info"
            if status_code >= 500:
                level = "error"
            elif status_code >= 400:
                level = "warn"

            message = f"{request.method} {path} → {status_code} ({duration_ms}ms)"
            if error_detail:
                message += f" | {error_detail}"

            # Always log to stdout so operators get live request visibility.
            stdlib_level = {"info": 20, "warn": 30, "error": 40}[level]
            _log.log(stdlib_level, message)

            # Persist to DB unless the path is in the skip list.
            if not any(path.startswith(p) for p in _DB_SKIP_PREFIXES):
                log_event(
                    level=level,
                    source="backend",
                    logger="http",
                    message=message,
                    request_path=path,
                    request_method=request.method,
                    status_code=status_code,
                    duration_ms=duration_ms,
                )
