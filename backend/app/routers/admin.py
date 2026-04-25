"""Admin dashboard API endpoints.

Provides database introspection, storage browsing, user analytics,
crash reports, and log viewing for the admin dashboard.
"""

import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import APIRouter, Depends, Query
from sqlalchemy import func, inspect, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.database import engine, get_db
from app.models.analytics import AppLog, CrashReport, PageVisit
from app.models.user import User
from app.storage import minio_client

router = APIRouter(prefix="/api/admin", tags=["admin"])

# ---------------------------------------------------------------------------
# Admin authentication
# ---------------------------------------------------------------------------
ADMIN_USERNAME = "inkspace"
ADMIN_PASSWORD = "Google@99"

# In-memory session tokens (reset on restart — fine for admin dashboard)
_admin_sessions: dict[str, datetime] = {}
SESSION_TTL = timedelta(hours=12)


def _verify_admin(token: str = Query(..., alias="token")):
    """Verify the admin session token passed as a query parameter."""
    session_expiry = _admin_sessions.get(token)
    if not session_expiry or datetime.now(timezone.utc) > session_expiry:
        _admin_sessions.pop(token, None)
        from fastapi import HTTPException, status

        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired session")


@router.post("/login")
async def admin_login(payload: dict):
    """Authenticate admin user and return a session token."""
    from fastapi import HTTPException, status

    username = payload.get("username", "")
    password = payload.get("password", "")

    if username != ADMIN_USERNAME or password != ADMIN_PASSWORD:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")

    token = secrets.token_urlsafe(32)
    _admin_sessions[token] = datetime.now(timezone.utc) + SESSION_TTL

    # Clean up expired sessions
    now = datetime.now(timezone.utc)
    expired = [k for k, v in _admin_sessions.items() if now > v]
    for k in expired:
        del _admin_sessions[k]

    return {"token": token, "expires_in": int(SESSION_TTL.total_seconds())}


# ── Overview ────────────────────────────────────────────────────────────────

@router.get("/overview")
async def overview(
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """High-level dashboard stats."""
    now = datetime.now(timezone.utc)
    day_ago = now - timedelta(days=1)
    week_ago = now - timedelta(days=7)

    total_users = (await db.execute(select(func.count(User.id)))).scalar() or 0
    total_writings = (await db.execute(text("SELECT count(*) FROM writings"))).scalar() or 0
    total_feed = (await db.execute(text("SELECT count(*) FROM feed_items"))).scalar() or 0
    total_crashes = (await db.execute(select(func.count(CrashReport.id)))).scalar() or 0
    unresolved_crashes = (
        await db.execute(
            select(func.count(CrashReport.id)).where(CrashReport.resolved == False)  # noqa: E712
        )
    ).scalar() or 0

    visits_today = (
        await db.execute(
            select(func.count(PageVisit.id)).where(PageVisit.visited_at >= day_ago)
        )
    ).scalar() or 0

    visits_week = (
        await db.execute(
            select(func.count(PageVisit.id)).where(PageVisit.visited_at >= week_ago)
        )
    ).scalar() or 0

    new_users_week = (
        await db.execute(
            select(func.count(User.id)).where(User.created_at >= week_ago)
        )
    ).scalar() or 0

    errors_today = (
        await db.execute(
            select(func.count(AppLog.id)).where(
                AppLog.level == "error", AppLog.created_at >= day_ago
            )
        )
    ).scalar() or 0

    return {
        "total_users": total_users,
        "new_users_week": new_users_week,
        "total_writings": total_writings,
        "total_feed_items": total_feed,
        "total_crashes": total_crashes,
        "unresolved_crashes": unresolved_crashes,
        "visits_today": visits_today,
        "visits_week": visits_week,
        "errors_today": errors_today,
    }


# ── Database tables ─────────────────────────────────────────────────────────

@router.get("/database/tables")
async def list_tables(_=Depends(_verify_admin)):
    """List all PostgreSQL tables with row counts."""
    async with engine.connect() as conn:
        result = await conn.execute(
            text(
                """
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = 'public'
                ORDER BY table_name
                """
            )
        )
        tables = [row[0] for row in result.fetchall()]

        table_info = []
        for t in tables:
            count_result = await conn.execute(text(f'SELECT count(*) FROM "{t}"'))  # noqa: S608
            row_count = count_result.scalar()
            table_info.append({"name": t, "row_count": row_count})

    return table_info


@router.get("/database/tables/{table_name}/schema")
async def table_schema(table_name: str, _=Depends(_verify_admin)):
    """Return column definitions for a table."""
    async with engine.connect() as conn:
        result = await conn.execute(
            text(
                """
                SELECT column_name, data_type, is_nullable, column_default
                FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = :t
                ORDER BY ordinal_position
                """
            ),
            {"t": table_name},
        )
        columns = [
            {
                "name": row[0],
                "type": row[1],
                "nullable": row[2] == "YES",
                "default": row[3],
            }
            for row in result.fetchall()
        ]
    return {"table": table_name, "columns": columns}


@router.get("/database/tables/{table_name}/data")
async def table_data(
    table_name: str,
    page: int = Query(1, ge=1),
    per_page: int = Query(50, ge=1, le=200),
    _=Depends(_verify_admin),
):
    """Paginated table rows (read-only)."""
    offset = (page - 1) * per_page
    async with engine.connect() as conn:
        # Validate table exists
        check = await conn.execute(
            text(
                "SELECT 1 FROM information_schema.tables "
                "WHERE table_schema='public' AND table_name=:t"
            ),
            {"t": table_name},
        )
        if check.fetchone() is None:
            from fastapi import HTTPException

            raise HTTPException(status_code=404, detail="Table not found")

        count_result = await conn.execute(text(f'SELECT count(*) FROM "{table_name}"'))  # noqa: S608
        total = count_result.scalar()

        result = await conn.execute(
            text(f'SELECT * FROM "{table_name}" LIMIT :lim OFFSET :off'),  # noqa: S608
            {"lim": per_page, "off": offset},
        )
        columns = list(result.keys())
        rows = []
        for row in result.fetchall():
            rows.append({col: _serialize(val) for col, val in zip(columns, row)})

    return {
        "table": table_name,
        "columns": columns,
        "rows": rows,
        "total": total,
        "page": page,
        "per_page": per_page,
        "total_pages": (total + per_page - 1) // per_page if total else 0,
    }


# ── Storage (MinIO) ────────────────────────────────────────────────────────

@router.get("/storage/buckets")
async def list_buckets(_=Depends(_verify_admin)):
    """List all MinIO buckets."""
    buckets = await minio_client.list_buckets()
    return [{"name": b.name, "created": b.creation_date.isoformat() if b.creation_date else None} for b in buckets]


@router.get("/storage/browse/{bucket}")
async def browse_bucket(
    bucket: str,
    prefix: str = Query("", description="Folder prefix"),
    _=Depends(_verify_admin),
):
    """Browse objects in a bucket."""
    objects = []
    async for obj in minio_client.list_objects(bucket, prefix=prefix or None, recursive=False):
        objects.append(
            {
                "name": obj.object_name,
                "size": obj.size,
                "is_dir": obj.is_dir,
                "last_modified": obj.last_modified.isoformat() if obj.last_modified else None,
                "content_type": getattr(obj, "content_type", None),
            }
        )
    return {"bucket": bucket, "prefix": prefix, "objects": objects}


@router.get("/storage/stats")
async def storage_stats(_=Depends(_verify_admin)):
    """Aggregate storage statistics."""
    bucket = settings.minio_bucket
    total_size = 0
    total_objects = 0
    by_type: dict[str, dict[str, Any]] = {}
    async for obj in minio_client.list_objects(bucket, recursive=True):
        if obj.is_dir:
            continue
        total_objects += 1
        total_size += obj.size or 0
        ext = (obj.object_name or "").rsplit(".", 1)[-1].lower() if "." in (obj.object_name or "") else "other"
        entry = by_type.setdefault(ext, {"count": 0, "size": 0})
        entry["count"] += 1
        entry["size"] += obj.size or 0

    return {
        "bucket": bucket,
        "total_objects": total_objects,
        "total_size_bytes": total_size,
        "total_size_mb": round(total_size / (1024 * 1024), 2),
        "by_type": by_type,
    }


# ── User Activity & Analytics ──────────────────────────────────────────────

@router.post("/track/visit")
async def track_visit(
    payload: dict,
    db: AsyncSession = Depends(get_db),
):
    """Record a page visit from the Flutter app."""
    visit = PageVisit(
        user_id=payload.get("user_id"),
        page=payload["page"],
        referrer=payload.get("referrer"),
        session_id=payload.get("session_id"),
        device=payload.get("device"),
        platform=payload.get("platform"),
        duration_ms=payload.get("duration_ms"),
    )
    db.add(visit)
    await db.commit()
    return {"status": "ok"}


@router.get("/analytics/page-visits")
async def page_visit_analytics(
    days: int = Query(7, ge=1, le=90),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Page visit counts grouped by page and day."""
    since = datetime.now(timezone.utc) - timedelta(days=days)
    result = await db.execute(
        select(
            PageVisit.page,
            func.date_trunc("day", PageVisit.visited_at).label("day"),
            func.count().label("visits"),
        )
        .where(PageVisit.visited_at >= since)
        .group_by(PageVisit.page, "day")
        .order_by(text("day"))
    )
    rows = result.fetchall()
    return [
        {"page": r[0], "day": r[1].isoformat() if r[1] else None, "visits": r[2]}
        for r in rows
    ]


@router.get("/analytics/top-pages")
async def top_pages(
    days: int = Query(7, ge=1, le=90),
    limit: int = Query(10, ge=1, le=50),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Most visited pages."""
    since = datetime.now(timezone.utc) - timedelta(days=days)
    result = await db.execute(
        select(PageVisit.page, func.count().label("visits"))
        .where(PageVisit.visited_at >= since)
        .group_by(PageVisit.page)
        .order_by(text("visits DESC"))
        .limit(limit)
    )
    return [{"page": r[0], "visits": r[1]} for r in result.fetchall()]


@router.get("/analytics/user-activity")
async def user_activity(
    days: int = Query(7, ge=1, le=90),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Daily active users and new users."""
    since = datetime.now(timezone.utc) - timedelta(days=days)

    # Daily active users (unique visitors)
    dau_result = await db.execute(
        select(
            func.date_trunc("day", PageVisit.visited_at).label("day"),
            func.count(func.distinct(PageVisit.user_id)).label("active_users"),
            func.count().label("total_visits"),
        )
        .where(PageVisit.visited_at >= since)
        .group_by("day")
        .order_by(text("day"))
    )
    dau = [
        {"day": r[0].isoformat() if r[0] else None, "active_users": r[1], "total_visits": r[2]}
        for r in dau_result.fetchall()
    ]

    # New user registrations per day
    new_users_result = await db.execute(
        select(
            func.date_trunc("day", User.created_at).label("day"),
            func.count().label("new_users"),
        )
        .where(User.created_at >= since)
        .group_by("day")
        .order_by(text("day"))
    )
    new_users = [
        {"day": r[0].isoformat() if r[0] else None, "new_users": r[1]}
        for r in new_users_result.fetchall()
    ]

    # Platform breakdown
    platform_result = await db.execute(
        select(PageVisit.platform, func.count().label("count"))
        .where(PageVisit.visited_at >= since)
        .group_by(PageVisit.platform)
    )
    platforms = [{"platform": r[0] or "unknown", "count": r[1]} for r in platform_result.fetchall()]

    return {"daily_active_users": dau, "new_users": new_users, "platforms": platforms}


# ── Crash Reports ──────────────────────────────────────────────────────────

@router.post("/crashes")
async def report_crash(
    payload: dict,
    db: AsyncSession = Depends(get_db),
):
    """Receive a crash report from the app."""
    crash = CrashReport(
        user_id=payload.get("user_id"),
        error_type=payload["error_type"],
        error_message=payload["error_message"],
        stack_trace=payload.get("stack_trace"),
        page=payload.get("page"),
        device=payload.get("device"),
        platform=payload.get("platform"),
        app_version=payload.get("app_version"),
    )
    db.add(crash)
    await db.commit()
    return {"status": "ok", "id": str(crash.id)}


@router.get("/crashes")
async def list_crashes(
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=100),
    resolved: bool | None = None,
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """List crash reports with pagination."""
    q = select(CrashReport).order_by(CrashReport.created_at.desc())
    if resolved is not None:
        q = q.where(CrashReport.resolved == resolved)

    total_q = select(func.count(CrashReport.id))
    if resolved is not None:
        total_q = total_q.where(CrashReport.resolved == resolved)
    total = (await db.execute(total_q)).scalar() or 0

    result = await db.execute(q.offset((page - 1) * per_page).limit(per_page))
    crashes = result.scalars().all()

    return {
        "crashes": [
            {
                "id": str(c.id),
                "error_type": c.error_type,
                "error_message": c.error_message,
                "stack_trace": c.stack_trace,
                "page": c.page,
                "device": c.device,
                "platform": c.platform,
                "app_version": c.app_version,
                "resolved": c.resolved,
                "created_at": c.created_at.isoformat(),
            }
            for c in crashes
        ],
        "total": total,
        "page": page,
        "per_page": per_page,
    }


@router.patch("/crashes/{crash_id}/resolve")
async def resolve_crash(
    crash_id: str,
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Mark a crash as resolved."""
    from uuid import UUID as _UUID

    result = await db.execute(select(CrashReport).where(CrashReport.id == _UUID(crash_id)))
    crash = result.scalar_one_or_none()
    if not crash:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="Crash not found")
    crash.resolved = True
    await db.commit()
    return {"status": "resolved"}


# ── Logs ───────────────────────────────────────────────────────────────────

@router.post("/logs")
async def ingest_log(
    payload: dict,
    db: AsyncSession = Depends(get_db),
):
    """Ingest a log entry from frontend or backend."""
    log = AppLog(
        level=payload.get("level", "info"),
        source=payload.get("source", "frontend"),
        logger=payload.get("logger"),
        message=payload["message"],
        details=payload.get("details"),
        user_id=payload.get("user_id"),
        request_path=payload.get("request_path"),
        request_method=payload.get("request_method"),
        status_code=payload.get("status_code"),
        duration_ms=payload.get("duration_ms"),
    )
    db.add(log)
    await db.commit()
    return {"status": "ok"}


@router.get("/logs")
async def list_logs(
    page: int = Query(1, ge=1),
    per_page: int = Query(50, ge=1, le=200),
    level: str | None = Query(None, description="Filter by level: info, warn, error"),
    source: str | None = Query(None, description="Filter by source: backend, frontend"),
    search: str | None = Query(None, description="Search in message"),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Query logs with filters."""
    q = select(AppLog).order_by(AppLog.created_at.desc())
    count_q = select(func.count(AppLog.id))

    if level:
        q = q.where(AppLog.level == level)
        count_q = count_q.where(AppLog.level == level)
    if source:
        q = q.where(AppLog.source == source)
        count_q = count_q.where(AppLog.source == source)
    if search:
        q = q.where(AppLog.message.ilike(f"%{search}%"))
        count_q = count_q.where(AppLog.message.ilike(f"%{search}%"))

    total = (await db.execute(count_q)).scalar() or 0
    result = await db.execute(q.offset((page - 1) * per_page).limit(per_page))
    logs = result.scalars().all()

    return {
        "logs": [
            {
                "id": str(l.id),
                "level": l.level,
                "source": l.source,
                "logger": l.logger,
                "message": l.message,
                "details": l.details,
                "request_path": l.request_path,
                "request_method": l.request_method,
                "status_code": l.status_code,
                "duration_ms": l.duration_ms,
                "created_at": l.created_at.isoformat(),
            }
            for l in logs
        ],
        "total": total,
        "page": page,
        "per_page": per_page,
    }


@router.get("/logs/stats")
async def log_stats(
    days: int = Query(7, ge=1, le=90),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Log level counts over time."""
    since = datetime.now(timezone.utc) - timedelta(days=days)
    result = await db.execute(
        select(
            AppLog.level,
            AppLog.source,
            func.date_trunc("day", AppLog.created_at).label("day"),
            func.count().label("count"),
        )
        .where(AppLog.created_at >= since)
        .group_by(AppLog.level, AppLog.source, "day")
        .order_by(text("day"))
    )
    return [
        {"level": r[0], "source": r[1], "day": r[2].isoformat() if r[2] else None, "count": r[3]}
        for r in result.fetchall()
    ]


# ── Helpers ────────────────────────────────────────────────────────────────

def _serialize(val: Any) -> Any:
    """Make arbitrary DB values JSON-safe."""
    if val is None:
        return None
    if isinstance(val, datetime):
        return val.isoformat()
    if isinstance(val, (int, float, bool, str)):
        return val
    return str(val)
