"""Application logging setup.

Configures Python's stdlib logging with:
  * a console handler (structured single-line format) so stdout captures everything
  * a DB handler that persists records to `app_logs` (non-blocking, background drain)

Anti-recursion: records emitted by SQLAlchemy / asyncpg / the drain task itself
are kept out of the DB handler — otherwise the INSERT into app_logs would trigger
fresh log records and loop forever.
"""

from __future__ import annotations

import asyncio
import logging
import sys
import traceback
import uuid
from queue import Empty, SimpleQueue
from typing import Any

from app.database import async_session
from app.models.analytics import AppLog

_LOG_FORMAT = "%(asctime)s %(levelname)-5s %(name)s | %(message)s"

# Loggers whose records MUST NOT be persisted to the DB — they would either
# recurse (the DB drivers themselves) or flood the table with noise.
_DB_HANDLER_BLOCKED = (
    "sqlalchemy",
    "asyncpg",
    "aiosqlite",
    "app.logger",          # the drain task itself
    "app.logger.db",       # internal signalling
)

# Map stdlib level name → our 3-bucket level stored in app_logs.
_LEVEL_BUCKET = {
    "DEBUG": "info",
    "INFO": "info",
    "WARNING": "warn",
    "ERROR": "error",
    "CRITICAL": "error",
}


class _DBLogHandler(logging.Handler):
    """Handler that enqueues records for an async drain task to persist.

    `emit` is called from arbitrary (sync) threads/contexts, so we cannot
    touch the DB directly — we just push onto a thread-safe queue.
    """

    def __init__(self, queue: "SimpleQueue[dict[str, Any]]") -> None:
        super().__init__()
        self._queue = queue

    def emit(self, record: logging.LogRecord) -> None:
        try:
            # Block specific loggers to prevent recursion / noise.
            if any(record.name == n or record.name.startswith(n + ".") for n in _DB_HANDLER_BLOCKED):
                return

            message = record.getMessage()
            details: str | None = None
            if record.exc_info:
                details = "".join(traceback.format_exception(*record.exc_info))

            self._queue.put_nowait({
                "level": _LEVEL_BUCKET.get(record.levelname, "info"),
                "source": "backend",
                "logger": record.name[:200],
                "message": message[:10000],
                "details": details,
            })
        except Exception:
            # Never let logging itself crash the app.
            pass


async def _drain_queue(queue: "SimpleQueue[dict[str, Any]]", stop: asyncio.Event) -> None:
    """Background task that flushes queued records to the DB in small batches."""

    BATCH = 50
    IDLE_SLEEP = 0.5

    while not stop.is_set():
        batch: list[dict[str, Any]] = []
        deadline = asyncio.get_event_loop().time() + IDLE_SLEEP
        while len(batch) < BATCH and asyncio.get_event_loop().time() < deadline:
            try:
                batch.append(queue.get_nowait())
            except Empty:
                if batch:
                    break
                await asyncio.sleep(0.05)

        if not batch:
            await asyncio.sleep(IDLE_SLEEP)
            continue

        # Sanitize user_id before insert — one bad UUID from an untrusted
        # client shouldn't drop the whole batch at commit time.
        for row in batch:
            uid = row.get("user_id")
            if uid is not None and not isinstance(uid, uuid.UUID):
                try:
                    row["user_id"] = uuid.UUID(str(uid))
                except (ValueError, TypeError):
                    row["user_id"] = None

        try:
            async with async_session() as session:
                session.add_all([AppLog(**row) for row in batch])
                await session.commit()
        except Exception as exc:
            # Last resort: print to stderr. We can't log without recursing.
            print(f"[logger] drain failed: {exc}", file=sys.stderr)


_queue: "SimpleQueue[dict[str, Any]] | None" = None
_drain_task: asyncio.Task[None] | None = None
_stop_event: asyncio.Event | None = None


def setup_logging(level: int = logging.INFO) -> None:
    """Install console + DB handlers on the root logger. Idempotent."""

    global _queue

    root = logging.getLogger()
    # Avoid double-configuration if called twice (e.g. reload).
    if any(isinstance(h, _DBLogHandler) for h in root.handlers):
        return

    root.setLevel(level)

    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(logging.Formatter(_LOG_FORMAT))
    console.setLevel(level)
    root.addHandler(console)

    _queue = SimpleQueue()
    db_handler = _DBLogHandler(_queue)
    db_handler.setLevel(logging.INFO)  # don't persist DEBUG to the DB
    root.addHandler(db_handler)

    # Quiet noisy libraries on console but keep their warnings/errors.
    logging.getLogger("sqlalchemy.engine").setLevel(logging.WARNING)
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)


async def start_drain() -> None:
    """Start the background drain task. Call from the FastAPI lifespan."""

    global _drain_task, _stop_event
    if _queue is None or _drain_task is not None:
        return
    _stop_event = asyncio.Event()
    _drain_task = asyncio.create_task(_drain_queue(_queue, _stop_event))


async def stop_drain() -> None:
    """Stop the drain task and flush remaining records. Call from lifespan shutdown."""

    global _drain_task, _stop_event
    if _drain_task is None or _stop_event is None:
        return
    _stop_event.set()
    try:
        await asyncio.wait_for(_drain_task, timeout=3.0)
    except (asyncio.TimeoutError, Exception):
        _drain_task.cancel()
    _drain_task = None
    _stop_event = None


def get_logger(name: str) -> logging.Logger:
    """Convenience wrapper so callers don't need to import `logging`."""

    return logging.getLogger(name)


def log_event(
    *,
    level: str,
    source: str,
    logger: str | None,
    message: str,
    details: str | None = None,
    user_id: Any = None,
    request_path: str | None = None,
    request_method: str | None = None,
    status_code: int | None = None,
    duration_ms: int | None = None,
) -> None:
    """Enqueue a log entry directly (used by the HTTP middleware and /api/logs ingest).

    Bypasses the stdlib logger so we can attach HTTP-specific metadata columns.
    """

    if _queue is None:
        return
    try:
        _queue.put_nowait({
            "level": level,
            "source": source,
            "logger": logger,
            "message": message[:10000] if message else "",
            "details": details,
            "user_id": user_id,
            "request_path": request_path[:500] if request_path else None,
            "request_method": request_method[:10] if request_method else None,
            "status_code": status_code,
            "duration_ms": duration_ms,
        })
    except Exception:
        pass


__all__ = [
    "setup_logging",
    "start_drain",
    "stop_drain",
    "get_logger",
    "log_event",
]
