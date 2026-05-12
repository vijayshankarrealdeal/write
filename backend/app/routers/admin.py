"""Admin dashboard API endpoints.

Provides database introspection, storage browsing, user analytics,
crash reports, and log viewing for the admin dashboard.
"""

import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from time import perf_counter
from typing import Any

from fastapi import APIRouter, Depends, Query
from passlib.context import CryptContext
from sqlalchemy import func, inspect, literal_column, or_, select, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.database import engine, get_db
from app.models.admin_audit import AdminAudit
from app.models.analytics import AnalyticsEvent, AppLog, CrashReport, PageVisit
from app.models.dictionary import (
    DictionaryMeta,
    DictionaryRemoval,
    DictionarySubmission,
    DictionaryWord,
)
from app.models.user import User
from app.storage import minio_client

_pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

router = APIRouter(prefix="/api/admin", tags=["admin"])

# ---------------------------------------------------------------------------
# Admin authentication — credentials sourced from env (ADMIN_USERNAME /
# ADMIN_PASSWORD), validated at startup in app.config.
# ---------------------------------------------------------------------------
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

    expected_user = settings.admin_username.encode()
    expected_pass = settings.admin_password.encode()
    user_ok = secrets.compare_digest(username.encode(), expected_user)
    pass_ok = secrets.compare_digest(password.encode(), expected_pass)
    if not (user_ok and pass_ok):
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
                AppLog.level == "error",
                AppLog.created_at >= day_ago,
                or_(AppLog.env.is_(None), AppLog.env != "dev"),
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


# ── Service health ──────────────────────────────────────────────────────────

# Live health check of backing services. Re-runs on every request so the
# admin dashboard sees real state after a page refresh — stale cached
# "OK"s would defeat the point. Each check is wrapped so one dead
# service doesn't poison the response for the others.

async def _timed(coro_factory) -> dict[str, Any]:
    t0 = perf_counter()
    try:
        await coro_factory()
        return {"status": "ok", "latency_ms": round((perf_counter() - t0) * 1000, 1)}
    except Exception as e:
        return {
            "status": "down",
            "latency_ms": round((perf_counter() - t0) * 1000, 1),
            "message": str(e)[:200],
        }


@router.get("/health")
async def services_health(
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    services: list[dict[str, Any]] = []

    services.append({"name": "Postgres", **await _timed(lambda: db.execute(text("SELECT 1")))})

    services.append({
        "name": "MinIO",
        **await _timed(lambda: minio_client.bucket_exists(settings.minio_bucket)),
    })

    if settings.redis_url:
        from redis import asyncio as redis_asyncio

        r = redis_asyncio.from_url(settings.redis_url, decode_responses=True)
        try:
            services.append({"name": "Redis", **await _timed(lambda: r.ping())})
        finally:
            await r.aclose()
    else:
        services.append({"name": "Redis", "status": "unconfigured", "message": "REDIS_URL not set"})

    # LLM: config-presence only — pinging Azure OpenAI on every dashboard
    # refresh would burn quota for no real signal.
    if settings.azure_openai_api_key and settings.azure_openai_endpoint:
        services.append({"name": "Azure OpenAI", "status": "ok", "message": "configured (not pinged)"})
    else:
        services.append({"name": "Azure OpenAI", "status": "unconfigured"})

    return {
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "services": services,
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
        await _assert_table_exists(conn, table_name)

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


# ── Database mutations (destructive — admin-only) ──────────────────────────

@router.patch("/database/tables/{table_name}/rows/{pk}")
async def update_row(
    table_name: str,
    pk: str,
    payload: dict,
    _=Depends(_verify_admin),
):
    """Update one row identified by its primary key.

    Body shape: {"updates": {"col1": value, "col2": value, ...}}
    Values may be strings, numbers, booleans, null, or JSON-serialisable
    objects (latter is sent to Postgres as a JSON string for jsonb columns).
    """
    from fastapi import HTTPException

    updates = payload.get("updates") or {}
    if not isinstance(updates, dict) or not updates:
        raise HTTPException(status_code=400, detail="updates object required")

    async with engine.begin() as conn:
        await _assert_table_exists(conn, table_name)
        pk_col = await _primary_key_column(conn, table_name)
        if pk_col is None:
            raise HTTPException(status_code=400, detail="Table has no single-column primary key")
        if pk_col in updates:
            raise HTTPException(status_code=400, detail="Cannot update primary key column")

        valid_cols = await _column_names(conn, table_name)
        bad = [c for c in updates if c not in valid_cols]
        if bad:
            raise HTTPException(status_code=400, detail=f"Unknown columns: {bad}")

        params: dict[str, Any] = {"_pk": pk}
        set_fragments: list[str] = []
        for col, val in updates.items():
            key = f"v_{col}"
            set_fragments.append(f'"{col}" = :{key}')
            params[key] = _coerce_inbound(val)

        sql = (
            f'UPDATE "{table_name}" SET {", ".join(set_fragments)} '
            f'WHERE "{pk_col}"::text = :_pk'
        )
        result = await conn.execute(text(sql), params)  # noqa: S608
        if result.rowcount == 0:
            raise HTTPException(status_code=404, detail="Row not found")

    return {"status": "ok", "updated": len(updates)}


@router.delete("/database/tables/{table_name}/rows/{pk}")
async def delete_row(
    table_name: str,
    pk: str,
    _=Depends(_verify_admin),
):
    """Delete a single row by primary key."""
    from fastapi import HTTPException

    async with engine.begin() as conn:
        await _assert_table_exists(conn, table_name)
        pk_col = await _primary_key_column(conn, table_name)
        if pk_col is None:
            raise HTTPException(status_code=400, detail="Table has no single-column primary key")

        result = await conn.execute(
            text(f'DELETE FROM "{table_name}" WHERE "{pk_col}"::text = :_pk'),  # noqa: S608
            {"_pk": pk},
        )
        if result.rowcount == 0:
            raise HTTPException(status_code=404, detail="Row not found")

    return {"status": "deleted"}


@router.post("/database/tables/{table_name}/clear")
async def clear_table(
    table_name: str,
    cascade: bool = Query(False, description="TRUNCATE ... CASCADE — also wipes FK-dependent rows"),
    restart_identity: bool = Query(True, description="Reset auto-increment sequences"),
    _=Depends(_verify_admin),
):
    """Truncate every row from a table. Irreversible."""
    async with engine.begin() as conn:
        await _assert_table_exists(conn, table_name)
        parts = [f'TRUNCATE TABLE "{table_name}"']
        if restart_identity:
            parts.append("RESTART IDENTITY")
        if cascade:
            parts.append("CASCADE")
        await conn.execute(text(" ".join(parts)))
    return {"status": "cleared", "table": table_name, "cascade": cascade}


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


@router.delete("/storage/objects/{bucket}")
async def delete_storage_object(
    bucket: str,
    key: str = Query(..., description="Object key to delete"),
    _=Depends(_verify_admin),
):
    """Remove a single object from a bucket."""
    await minio_client.remove_object(bucket, key)
    return {"status": "deleted", "bucket": bucket, "key": key}


@router.post("/storage/clear/{bucket}")
async def clear_storage_bucket(
    bucket: str,
    prefix: str = Query("", description="Optional prefix — only objects under this prefix are removed"),
    _=Depends(_verify_admin),
):
    """Delete every object in a bucket (or under a prefix). Irreversible."""
    count = 0
    async for obj in minio_client.list_objects(bucket, prefix=prefix or None, recursive=True):
        if obj.is_dir:
            continue
        await minio_client.remove_object(bucket, obj.object_name)
        count += 1
    return {"status": "cleared", "bucket": bucket, "prefix": prefix, "removed": count}


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


# All four endpoints below read from `analytics_events` — the table the
# Flutter `AnalyticsService` actually populates via /api/analytics/events.
# `screen_viewed` rows are the page-visit signal; the legacy `page_visits`
# table is left in place for back-compat but is not read here.
#
# Platform attribution: clients put `platform` (android/ios/web/macos/...)
# into `properties.platform`. When that's missing (older clients, anon
# events before the field shipped), we fall back to a coarse parse of the
# stored user-agent string.

# Filter: keep only production traffic. Clients tag every event with
# `properties.env` ∈ {prod, dev}; we treat NULL as prod for back-compat
# with rows written before the tag shipped.
_PROD_ONLY = text("COALESCE(properties->>'env', 'prod') <> 'dev'")

# Routes the admin doesn't want in page-visit charts — the writing/editor
# surfaces dominate sessions in raw counts and drown out the navigational
# pages we actually care about.
_WRITING_ROUTES = ("/editor", "/publish")
_NOT_WRITING = text(
    "NOT (screen LIKE '/editor%' OR screen LIKE '/publish%')"
)

# Restrict breakdowns to actual page views, not lifecycle/api events.
# Without this, app_foregrounded + every track() call inflates platform /
# device / region counts 3-5x and obscures real user behaviour.
_SCREEN_VIEWS = text("event_name = 'screen_viewed'")


# COALESCE(properties->>'platform', <UA fallback>) as a single SQL fragment.
# Order matters: Android UAs also contain "Linux", so check it first.
# `literal_column` (not `text`) so the expression supports `.label()` in
# `select()` — TextClause does not.
_PLATFORM_EXPR = literal_column(
    """
    COALESCE(
        NULLIF(properties->>'platform', ''),
        CASE
            WHEN user_agent ILIKE 'dart/%' THEN 'app-unknown'
            WHEN user_agent ILIKE '%android%' THEN 'android'
            WHEN user_agent ILIKE '%iphone%' OR user_agent ILIKE '%ipad%' OR user_agent ILIKE '%ios%' THEN 'ios'
            WHEN user_agent ILIKE '%mac os%' OR user_agent ILIKE '%macintosh%' THEN 'macos'
            WHEN user_agent ILIKE '%windows%' THEN 'windows'
            WHEN user_agent ILIKE '%linux%' THEN 'linux'
            WHEN user_agent ILIKE '%mozilla%' OR user_agent ILIKE '%chrome%' OR user_agent ILIKE '%safari%' THEN 'web'
            ELSE 'unknown'
        END
    )
    """
)


@router.get("/analytics/page-visits")
async def page_visit_analytics(
    days: int = Query(7, ge=1, le=90),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Page visit counts grouped by screen and day.

    Reads `screen_viewed` events from `analytics_events`. A row missing a
    screen name (rare — only background events) is skipped.
    """
    since = datetime.now(timezone.utc) - timedelta(days=days)
    result = await db.execute(
        select(
            AnalyticsEvent.screen,
            func.date_trunc("day", AnalyticsEvent.server_ts).label("day"),
            func.count().label("visits"),
        )
        .where(
            AnalyticsEvent.event_name == "screen_viewed",
            AnalyticsEvent.server_ts >= since,
            AnalyticsEvent.screen.isnot(None),
            _PROD_ONLY,
            _NOT_WRITING,
        )
        .group_by(AnalyticsEvent.screen, "day")
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
    """Most viewed screens, by event count."""
    since = datetime.now(timezone.utc) - timedelta(days=days)
    result = await db.execute(
        select(AnalyticsEvent.screen, func.count().label("visits"))
        .where(
            AnalyticsEvent.event_name == "screen_viewed",
            AnalyticsEvent.server_ts >= since,
            AnalyticsEvent.screen.isnot(None),
            _PROD_ONLY,
            _NOT_WRITING,
        )
        .group_by(AnalyticsEvent.screen)
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
    """Daily active users, total visits, new signups, platform mix.

    DAU counts distinct `client_id`s (so anonymous-but-active devices
    still register). Total visits is the count of `screen_viewed` events.
    """
    since = datetime.now(timezone.utc) - timedelta(days=days)

    dau_result = await db.execute(
        select(
            func.date_trunc("day", AnalyticsEvent.server_ts).label("day"),
            func.count(func.distinct(AnalyticsEvent.client_id)).label("active_users"),
            func.count(AnalyticsEvent.id).filter(
                AnalyticsEvent.event_name == "screen_viewed"
            ).label("total_visits"),
        )
        .where(AnalyticsEvent.server_ts >= since, _PROD_ONLY)
        .group_by("day")
        .order_by(text("day"))
    )
    dau = [
        {"day": r[0].isoformat() if r[0] else None, "active_users": r[1], "total_visits": r[2]}
        for r in dau_result.fetchall()
    ]

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

    # Platform mix is counted from screen-view events only — anything else
    # is lifecycle/api noise and obscures the actual reach of each OS.
    platform_result = await db.execute(
        select(_PLATFORM_EXPR.label("platform"), func.count().label("count"))
        .where(AnalyticsEvent.server_ts >= since, _PROD_ONLY, _SCREEN_VIEWS)
        .group_by(text("1"))
        .order_by(text("count DESC"))
    )
    platforms = [{"platform": r[0] or "unknown", "count": r[1]} for r in platform_result.fetchall()]

    return {"daily_active_users": dau, "new_users": new_users, "platforms": platforms}


@router.get("/analytics/devices")
async def device_breakdown(
    days: int = Query(30, ge=1, le=365),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Counts grouped by platform and device, plus signups over time.

    Device strings come from `properties.device` when the client supplies
    it (model name on mobile, browser+OS on web). User-agent is the
    fallback.
    """
    since = datetime.now(timezone.utc) - timedelta(days=days)

    platform_rows = (
        await db.execute(
            select(_PLATFORM_EXPR.label("platform"), func.count().label("count"))
            .where(AnalyticsEvent.server_ts >= since, _PROD_ONLY, _SCREEN_VIEWS)
            .group_by(text("1"))
            .order_by(text("count DESC"))
        )
    ).fetchall()

    # Prefer client-reported device, then a friendly label for our own
    # Dart HTTP client (which would otherwise dominate the chart as a
    # generic "Dart/3.11 (dart:io)" row that means nothing to the admin),
    # finally falling back to user_agent. `literal_column` (not `text`) —
    # TextClause does not support `.label()` in `select()`.
    device_expr = literal_column(
        """
        COALESCE(
            NULLIF(properties->>'device', ''),
            CASE
                WHEN user_agent ILIKE 'dart/%' THEN
                    'Flutter app · ' || COALESCE(NULLIF(properties->>'platform', ''), 'unknown')
                ELSE LEFT(COALESCE(user_agent, ''), 80)
            END
        )
        """
    )
    device_rows = (
        await db.execute(
            select(device_expr.label("device"), func.count().label("count"))
            .where(AnalyticsEvent.server_ts >= since, _PROD_ONLY, _SCREEN_VIEWS)
            .group_by(text("1"))
            .order_by(text("count DESC"))
            .limit(15)
        )
    ).fetchall()

    # Region is derived from the request IP, not the device locale —
    # locale defaults to en_US on most English-set phones, which tagged
    # most non-US English speakers as "US". We group events by IP first
    # (cheap, single index pass), then map each unique IP to a country
    # via Redis-cached lookups in app.geoip. Referrer is web-only and
    # supplied via properties.referrer.
    ip_count_rows = (
        await db.execute(
            select(AnalyticsEvent.ip, func.count().label("count"))
            .where(
                AnalyticsEvent.server_ts >= since,
                AnalyticsEvent.ip.is_not(None),
                _PROD_ONLY,
                _SCREEN_VIEWS,
            )
            .group_by(AnalyticsEvent.ip)
        )
    ).fetchall()

    from app.geoip import countries_for_ips

    ip_to_country = await countries_for_ips([str(r[0]) for r in ip_count_rows if r[0]])
    country_counts: dict[str, int] = {}
    for ip, count in ip_count_rows:
        cc = ip_to_country.get(str(ip)) if ip else None
        if cc:
            country_counts[cc] = country_counts.get(cc, 0) + int(count)
    region_rows = sorted(country_counts.items(), key=lambda kv: kv[1], reverse=True)[:25]

    referrer_rows = (
        await db.execute(
            select(literal_column("properties->>'referrer'").label("referrer"), func.count().label("count"))
            .where(
                AnalyticsEvent.server_ts >= since,
                text("(properties->>'referrer') IS NOT NULL"),
                text("(properties->>'referrer') <> ''"),
                _PROD_ONLY,
                _SCREEN_VIEWS,
            )
            .group_by(text("1"))
            .order_by(text("count DESC"))
            .limit(15)
        )
    ).fetchall()

    signup_rows = (
        await db.execute(
            select(
                func.date_trunc("day", User.created_at).label("day"),
                func.count().label("count"),
            )
            .where(User.created_at >= since)
            .group_by("day")
            .order_by(text("day"))
        )
    ).fetchall()

    return {
        "platforms": [{"label": r[0] or "unknown", "count": r[1]} for r in platform_rows],
        "devices": [{"label": (r[0] or "unknown")[:80], "count": r[1]} for r in device_rows],
        "regions": [{"label": r[0] or "unknown", "count": r[1]} for r in region_rows],
        "referrers": [{"label": r[0] or "direct", "count": r[1]} for r in referrer_rows],
        "signups_per_day": [
            {"day": r[0].isoformat() if r[0] else None, "count": r[1]} for r in signup_rows
        ],
    }


@router.get("/analytics/funnel")
async def acquisition_funnel(
    days: int = Query(30, ge=1, le=365),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Conversion funnel from first visit to onboarded user.

    Each step is a count of distinct `client_id`s that ever reached the
    screen within the window — session-level rather than event-level, so
    one curious user clicking around doesn't pad the numbers. The final
    "Onboarded" step joins on `users.onboarding_complete` to capture the
    only step that lives outside the analytics stream.
    """
    since = datetime.now(timezone.utc) - timedelta(days=days)

    async def _distinct_clients_on(screen: str) -> int:
        result = await db.execute(
            select(func.count(func.distinct(AnalyticsEvent.client_id)))
            .where(
                AnalyticsEvent.server_ts >= since,
                AnalyticsEvent.event_name == "screen_viewed",
                AnalyticsEvent.screen == screen,
                _PROD_ONLY,
            )
        )
        return int(result.scalar() or 0)

    # "Landed" is anyone with any screen view at all in the window — the
    # widest possible top-of-funnel.
    landed_result = await db.execute(
        select(func.count(func.distinct(AnalyticsEvent.client_id)))
        .where(
            AnalyticsEvent.server_ts >= since,
            AnalyticsEvent.event_name == "screen_viewed",
            _PROD_ONLY,
        )
    )
    landed = int(landed_result.scalar() or 0)

    saw_login = await _distinct_clients_on("/login")
    saw_signup = await _distinct_clients_on("/signup")
    saw_onboarding = await _distinct_clients_on("/onboarding")

    signed_up_result = await db.execute(
        select(func.count(User.id)).where(User.created_at >= since)
    )
    signed_up = int(signed_up_result.scalar() or 0)

    onboarded_result = await db.execute(
        select(func.count(User.id)).where(
            User.created_at >= since,
            User.onboarding_complete.is_(True),
        )
    )
    onboarded = int(onboarded_result.scalar() or 0)

    steps = [
        {"step": "Landed", "count": landed},
        {"step": "Saw /login", "count": saw_login},
        {"step": "Saw /signup", "count": saw_signup},
        {"step": "Signed up", "count": signed_up},
        {"step": "Saw /onboarding", "count": saw_onboarding},
        {"step": "Onboarded", "count": onboarded},
    ]
    # Conversion rate against the top of funnel, rounded to 0.1%.
    for s in steps:
        s["rate"] = round(100 * s["count"] / landed, 1) if landed else 0.0

    return {"days": days, "steps": steps}


# ── Writings (read-only, for user-behaviour insight) ───────────────────────
#
# Admin browses what users are actually writing — title, author, section
# tree, body — to understand how the editor is being used. Read-only:
# editing or deleting a user's writing belongs in the Database tab where
# the destructive action is explicit.

def _quill_delta_to_text(delta: Any) -> str:
    """Best-effort plain-text rendering of a Quill delta.

    Sections store body as a Quill delta (`{"ops": [...]}`). For an
    admin preview we only need readable text — newlines preserved,
    formatting dropped. Embeds (images / mentions) become a single
    placeholder so block layout is still visible.
    """
    if not delta:
        return ""
    if isinstance(delta, str):
        return delta
    if isinstance(delta, list):
        ops = delta
    elif isinstance(delta, dict):
        ops = delta.get("ops") or []
    else:
        return ""
    out: list[str] = []
    for op in ops:
        if not isinstance(op, dict):
            continue
        ins = op.get("insert")
        if isinstance(ins, str):
            out.append(ins)
        elif isinstance(ins, dict):
            # image / video / mention etc — keep block flow intact
            out.append("[embed]")
    return "".join(out)


@router.get("/writings")
async def list_writings(
    page: int = Query(1, ge=1),
    per_page: int = Query(25, ge=1, le=100),
    search: str | None = Query(None, description="Match title, author, or owner email"),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Paginated list of every writing in the system.

    Joined with the owner so the admin can see *who* wrote it. Section
    count and aggregate word count come from a per-writing subquery so
    one round-trip serves the whole page.
    """
    from sqlalchemy import desc

    from app.models.section import Section
    from app.models.writing import Writing

    # Base query — join owner once.
    q = (
        select(
            Writing.id,
            Writing.title,
            Writing.author,
            Writing.writing_type,
            Writing.subtype,
            Writing.status,
            Writing.created_at,
            Writing.updated_at,
            User.id.label("user_id"),
            User.email,
            User.name,
        )
        .join(User, User.id == Writing.user_id)
    )

    if search:
        like = f"%{search.strip().lower()}%"
        q = q.where(
            or_(
                func.lower(Writing.title).like(like),
                func.lower(Writing.author).like(like),
                func.lower(User.email).like(like),
                func.lower(User.name).like(like),
            )
        )

    total = (
        await db.execute(select(func.count()).select_from(q.subquery()))
    ).scalar() or 0

    rows = (
        await db.execute(
            q.order_by(desc(Writing.updated_at))
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
    ).fetchall()

    writing_ids = [r[0] for r in rows]
    section_counts: dict[Any, int] = {}
    if writing_ids:
        cnt_rows = (
            await db.execute(
                select(Section.writing_id, func.count())
                .where(Section.writing_id.in_(writing_ids))
                .group_by(Section.writing_id)
            )
        ).fetchall()
        section_counts = {wid: cnt for wid, cnt in cnt_rows}

    return {
        "writings": [
            {
                "id": str(r.id),
                "title": r.title or "Untitled",
                "author": r.author,
                "writing_type": r.writing_type,
                "subtype": r.subtype,
                "status": r.status,
                "section_count": section_counts.get(r.id, 0),
                "created_at": r.created_at.isoformat() if r.created_at else None,
                "updated_at": r.updated_at.isoformat() if r.updated_at else None,
                "owner": {
                    "id": str(r.user_id),
                    "email": r.email,
                    "name": r.name,
                },
            }
            for r in rows
        ],
        "page": page,
        "per_page": per_page,
        "total": total,
        "total_pages": (total + per_page - 1) // per_page,
    }


@router.get("/writings/{writing_id}")
async def get_writing_detail(
    writing_id: str,
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Single writing plus every section, ready to read in the dashboard."""
    from fastapi import HTTPException

    from app.models.section import Section
    from app.models.writing import Writing

    row = (
        await db.execute(
            select(
                Writing,
                User.id.label("uid"),
                User.email,
                User.name,
            )
            .join(User, User.id == Writing.user_id)
            .where(Writing.id == writing_id)
        )
    ).first()
    if not row:
        raise HTTPException(status_code=404, detail="Writing not found")

    writing: Any = row[0]

    sections = (
        await db.execute(
            select(Section)
            .where(Section.writing_id == writing.id)
            .order_by(Section.sort_order, Section.updated_at)
        )
    ).scalars().all()

    section_payload = []
    total_words = 0
    for s in sections:
        body = _quill_delta_to_text(s.content)
        words = len(body.split()) if body else 0
        total_words += words
        section_payload.append(
            {
                "id": str(s.id),
                "title": s.title or "Untitled",
                "kind": s.kind,
                "synopsis": s.synopsis,
                "is_published": s.is_published,
                "is_free_preview": s.is_free_preview,
                "include_in_publish": s.include_in_publish,
                "parent_id": s.parent_id,
                "sort_order": s.sort_order,
                "word_count": words,
                "body": body,
                "updated_at": s.updated_at.isoformat() if s.updated_at else None,
            }
        )

    return {
        "id": str(writing.id),
        "title": writing.title or "Untitled",
        "author": writing.author,
        "description": writing.description,
        "writing_type": writing.writing_type,
        "subtype": writing.subtype,
        "status": writing.status,
        "target_word_count": writing.target_word_count,
        "target_deadline": writing.target_deadline.isoformat() if writing.target_deadline else None,
        "created_at": writing.created_at.isoformat() if writing.created_at else None,
        "updated_at": writing.updated_at.isoformat() if writing.updated_at else None,
        "owner": {
            "id": str(row.uid),
            "email": row.email,
            "name": row.name,
        },
        "total_words": total_words,
        "section_count": len(section_payload),
        "sections": section_payload,
    }


# ── Users (admin-managed) ──────────────────────────────────────────────────

@router.get("/users")
async def list_users(
    page: int = Query(1, ge=1),
    per_page: int = Query(25, ge=1, le=200),
    search: str | None = Query(None, description="Match email or name"),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Paginated user directory for the admin console."""
    q = select(User).order_by(User.created_at.desc())
    count_q = select(func.count(User.id))
    if search:
        like = f"%{search}%"
        q = q.where(or_(User.email.ilike(like), User.name.ilike(like)))
        count_q = count_q.where(or_(User.email.ilike(like), User.name.ilike(like)))

    total = (await db.execute(count_q)).scalar() or 0
    result = await db.execute(q.offset((page - 1) * per_page).limit(per_page))
    users = result.scalars().all()

    return {
        "users": [
            {
                "id": str(u.id),
                "email": u.email,
                "name": u.name,
                "photo_url": u.photo_url,
                "onboarding_complete": u.onboarding_complete,
                "has_password": bool(u.password_hash),
                "created_at": u.created_at.isoformat() if u.created_at else None,
            }
            for u in users
        ],
        "total": total,
        "page": page,
        "per_page": per_page,
        "total_pages": (total + per_page - 1) // per_page if total else 0,
    }


@router.post("/users")
async def create_user(
    payload: dict,
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Create a user with email/name/password from the admin console."""
    from fastapi import HTTPException

    email = (payload.get("email") or "").strip().lower()
    password = payload.get("password") or ""
    name = (payload.get("name") or "").strip() or None

    if not email or "@" not in email:
        raise HTTPException(status_code=400, detail="Valid email required")
    if len(password) < 8:
        raise HTTPException(status_code=400, detail="Password must be at least 8 characters")

    existing = await db.execute(select(User).where(User.email == email))
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="Email already registered")

    user = User(
        email=email,
        name=name,
        password_hash=_pwd_context.hash(password),
        onboarding_complete=bool(payload.get("onboarding_complete", False)),
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)

    return {
        "id": str(user.id),
        "email": user.email,
        "name": user.name,
        "created_at": user.created_at.isoformat() if user.created_at else None,
    }


@router.post("/users/{user_id}/reset-password")
async def admin_reset_password(
    user_id: str,
    payload: dict,
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Force-reset a user's password from the admin console."""
    from fastapi import HTTPException
    from uuid import UUID as _UUID

    password = payload.get("password") or ""
    if len(password) < 8:
        raise HTTPException(status_code=400, detail="Password must be at least 8 characters")

    result = await db.execute(select(User).where(User.id == _UUID(user_id)))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    user.password_hash = _pwd_context.hash(password)
    await db.commit()
    return {"status": "ok"}


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
    env: str | None = Query(None, description="Filter by env: dev, prod"),
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
    if env:
        q = q.where(AppLog.env == env)
        count_q = count_q.where(AppLog.env == env)
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
                "env": l.env,
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
    source: str | None = Query(None, description="Filter by source: backend, frontend"),
    env: str | None = Query(None, description="Filter by env: dev, prod"),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Log level counts over time. Honours source+env filters so the chart
    matches whatever the list view is showing."""
    since = datetime.now(timezone.utc) - timedelta(days=days)
    q = (
        select(
            AppLog.level,
            AppLog.source,
            AppLog.env,
            func.date_trunc("day", AppLog.created_at).label("day"),
            func.count().label("count"),
        )
        .where(AppLog.created_at >= since)
        .group_by(AppLog.level, AppLog.source, AppLog.env, "day")
        .order_by(text("day"))
    )
    if source:
        q = q.where(AppLog.source == source)
    if env:
        q = q.where(AppLog.env == env)
    result = await db.execute(q)
    return [
        {
            "level": r[0],
            "source": r[1],
            "env": r[2],
            "day": r[3].isoformat() if r[3] else None,
            "count": r[4],
        }
        for r in result.fetchall()
    ]


# ── Dictionary (admin merge of user-submitted words) ──────────────────────


@router.get("/dictionary/stats")
async def dictionary_stats(
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Counts for the dictionary admin landing card."""
    pending = (
        await db.execute(
            select(func.count(DictionarySubmission.id)).where(
                DictionarySubmission.status == "pending"
            )
        )
    ).scalar() or 0
    approved = (
        await db.execute(
            select(func.count(DictionarySubmission.id)).where(
                DictionarySubmission.status == "approved"
            )
        )
    ).scalar() or 0
    rejected = (
        await db.execute(
            select(func.count(DictionarySubmission.id)).where(
                DictionarySubmission.status == "rejected"
            )
        )
    ).scalar() or 0
    total_words = (
        await db.execute(select(func.count(DictionaryWord.word)))
    ).scalar() or 0
    version = (
        await db.execute(select(DictionaryMeta.version))
    ).scalar() or 0
    return {
        "pending": pending,
        "approved": approved,
        "rejected": rejected,
        "global_words": total_words,
        "version": version,
    }


@router.get("/dictionary/submissions")
async def list_submissions(
    page: int = Query(1, ge=1),
    per_page: int = Query(50, ge=1, le=200),
    status: str | None = Query(None, description="pending | approved | rejected"),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Paginated raw-submission queue. Most recent first."""
    q = select(
        DictionarySubmission.id,
        DictionarySubmission.word,
        DictionarySubmission.language,
        DictionarySubmission.status,
        DictionarySubmission.note,
        DictionarySubmission.created_at,
        DictionarySubmission.processed_at,
        # Distinct-user count per word so admins can eyeball
        # popularity even before the merge runs.
        func.count(DictionarySubmission.user_id).over(
            partition_by=(
                DictionarySubmission.word,
                DictionarySubmission.language,
            )
        ).label("submitter_count"),
    ).order_by(DictionarySubmission.created_at.desc())
    count_q = select(func.count(DictionarySubmission.id))
    if status:
        q = q.where(DictionarySubmission.status == status)
        count_q = count_q.where(DictionarySubmission.status == status)

    total = (await db.execute(count_q)).scalar() or 0
    rows = await db.execute(q.offset((page - 1) * per_page).limit(per_page))
    return {
        "submissions": [
            {
                "id": str(r.id),
                "word": r.word,
                "language": r.language,
                "status": r.status,
                "note": r.note,
                "created_at": r.created_at.isoformat() if r.created_at else None,
                "processed_at": (
                    r.processed_at.isoformat() if r.processed_at else None
                ),
                "submitter_count": r.submitter_count,
            }
            for r in rows.all()
        ],
        "total": total,
        "page": page,
        "per_page": per_page,
        "total_pages": (total + per_page - 1) // per_page if total else 0,
    }


@router.get("/dictionary/words")
async def list_global_words(
    page: int = Query(1, ge=1),
    per_page: int = Query(100, ge=1, le=500),
    search: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Paginated browse of the merged global dictionary."""
    q = select(
        DictionaryWord.word,
        DictionaryWord.language,
        DictionaryWord.source,
        DictionaryWord.submission_count,
        DictionaryWord.added_in_version,
        DictionaryWord.created_at,
    ).order_by(DictionaryWord.created_at.desc())
    count_q = select(func.count(DictionaryWord.word))
    if search:
        like = f"%{search.lower()}%"
        q = q.where(DictionaryWord.word.ilike(like))
        count_q = count_q.where(DictionaryWord.word.ilike(like))
    total = (await db.execute(count_q)).scalar() or 0
    rows = await db.execute(q.offset((page - 1) * per_page).limit(per_page))
    return {
        "words": [
            {
                "word": r.word,
                "language": r.language,
                "source": r.source,
                "submission_count": r.submission_count,
                "added_in_version": r.added_in_version,
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
            for r in rows.all()
        ],
        "total": total,
        "page": page,
        "per_page": per_page,
        "total_pages": (total + per_page - 1) // per_page if total else 0,
    }


@router.delete("/dictionary/words/{word}")
async def delete_global_word(
    word: str,
    language: str = Query(default="en"),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Pull a word from the global dictionary, broadcast the change.

    Bumps the version, writes a tombstone so client caches drop the
    word too, and reloads the in-memory spell-check engine so the
    next ``/api/spellcheck/check`` re-flags it.
    """
    from app import spellcheck as engine_mod
    from app.realtime import hub as realtime_hub

    word_l = word.strip().lower()
    lang_l = language.strip().lower()

    deleted = await db.execute(
        DictionaryWord.__table__.delete().where(
            DictionaryWord.word == word_l, DictionaryWord.language == lang_l
        )
    )
    if deleted.rowcount == 0:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="Word not found")

    new_version = await _bump_dict_version(db)
    await db.execute(
        pg_insert(DictionaryRemoval)
        .values(
            word=word_l, language=lang_l, removed_in_version=new_version
        )
        .on_conflict_do_update(
            index_elements=["word", "language"],
            set_={"removed_in_version": new_version},
        )
    )
    await _record_admin_audit(
        db,
        action="dictionary.word.remove",
        target={"word": word_l, "language": lang_l, "version": new_version},
    )
    await db.commit()

    engine_mod.remove_words([word_l])
    await realtime_hub.broadcast_dictionary(
        {"type": "dictionary.updated", "version": new_version}
    )
    return {"status": "removed", "word": word_l, "version": new_version}


@router.post("/dictionary/merge")
async def merge_dictionary(
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Run the AI pipeline on every pending submission, accept the good
    ones into the global dictionary, mark the rest rejected.

    Atomic per word: a single failed classification doesn't block the
    rest of the batch. Bumps the dictionary version once at the end so
    every accepted word lands in the same delta.
    """
    from app import spellcheck as engine_mod
    from app.ai.dictionary_merge import classify_words
    from app.realtime import hub as realtime_hub

    pending = (
        await db.execute(
            select(
                DictionarySubmission.word,
                DictionarySubmission.language,
                func.count(DictionarySubmission.id).label("count"),
            )
            .where(DictionarySubmission.status == "pending")
            .group_by(DictionarySubmission.word, DictionarySubmission.language)
        )
    ).all()

    if not pending:
        version = (
            await db.execute(select(DictionaryMeta.version))
        ).scalar() or 0
        return {
            "status": "noop",
            "version": version,
            "accepted": 0,
            "rejected": 0,
        }

    # Words already in the global dict — flip their submissions to
    # approved without round-tripping the classifier.
    existing_rows = await db.execute(
        select(DictionaryWord.word, DictionaryWord.language)
    )
    existing = {(w, l) for w, l in existing_rows.all()}

    candidates: list[tuple[str, str, int]] = []
    auto_approved: list[tuple[str, str]] = []
    for word, lang, count in pending:
        if (word, lang) in existing:
            auto_approved.append((word, lang))
        else:
            candidates.append((word, lang, count))

    verdict_words = [w for w, _, _ in candidates]
    verdicts = await classify_words(verdict_words) if verdict_words else []
    verdict_map = {v.word: v for v in verdicts}

    accepted_now: list[tuple[str, str, int, str]] = []  # word, lang, count, note
    rejected_now: list[tuple[str, str, str]] = []  # word, lang, note
    for word, lang, count in candidates:
        v = verdict_map.get(word)
        if v is None:
            rejected_now.append((word, lang, "no verdict"))
            continue
        if v.verdict == "accept":
            accepted_now.append((word, lang, count, v.note))
        else:
            rejected_now.append((word, lang, v.note))

    # Bump the version exactly once for the whole merge so every
    # accepted word shares an ``added_in_version`` and the SSE event
    # we broadcast points clients at a single delta.
    new_version = await _bump_dict_version(db)
    now = datetime.now(timezone.utc)

    if accepted_now:
        # Insert into global dict; on conflict bump the
        # submission_count so re-merges accumulate popularity rather
        # than overwriting it.
        for word, lang, count, _note in accepted_now:
            await db.execute(
                pg_insert(DictionaryWord)
                .values(
                    word=word,
                    language=lang,
                    source="merged",
                    submission_count=count,
                    added_in_version=new_version,
                )
                .on_conflict_do_update(
                    index_elements=["word", "language"],
                    set_={
                        "submission_count": (
                            DictionaryWord.submission_count + count
                        ),
                    },
                )
            )

    # Flip submission rows to their final status. Done after the
    # word-level upserts so nothing approves on disk that didn't make
    # it into dictionary_words.
    if auto_approved:
        await db.execute(
            DictionarySubmission.__table__.update()
            .where(
                DictionarySubmission.status == "pending",
                DictionarySubmission.word.in_([w for w, _ in auto_approved]),
            )
            .values(status="approved", processed_at=now, note="already in global dict")
        )
    for word, lang, _count, note in accepted_now:
        await db.execute(
            DictionarySubmission.__table__.update()
            .where(
                DictionarySubmission.status == "pending",
                DictionarySubmission.word == word,
                DictionarySubmission.language == lang,
            )
            .values(status="approved", processed_at=now, note=note or None)
        )
    for word, lang, note in rejected_now:
        await db.execute(
            DictionarySubmission.__table__.update()
            .where(
                DictionarySubmission.status == "pending",
                DictionarySubmission.word == word,
                DictionarySubmission.language == lang,
            )
            .values(status="rejected", processed_at=now, note=note or None)
        )

    # Audit row carries the words touched (capped) so an investigator
    # can answer "did admin X accept slur Y on date Z?" without
    # cross-referencing the submission table on its own.
    _AUDIT_WORD_CAP = 200
    await _record_admin_audit(
        db,
        action="dictionary.merge",
        target={
            "version": new_version,
            "accepted_count": len(accepted_now) + len(auto_approved),
            "rejected_count": len(rejected_now),
            "accepted_words": [w for w, _, _, _ in accepted_now][:_AUDIT_WORD_CAP],
            "auto_approved_words": [w for w, _ in auto_approved][:_AUDIT_WORD_CAP],
            "rejected_words": [w for w, _, _ in rejected_now][:_AUDIT_WORD_CAP],
        },
    )

    await db.commit()

    # Hot-reload the in-memory checker and notify every connected
    # client. The SSE event itself carries only the new version — no
    # word strings — so a passive listener leaks nothing.
    if accepted_now:
        engine_mod.add_words([w for w, _, _, _ in accepted_now])
    await realtime_hub.broadcast_dictionary(
        {"type": "dictionary.updated", "version": new_version}
    )

    return {
        "status": "ok",
        "version": new_version,
        "accepted": len(accepted_now) + len(auto_approved),
        "rejected": len(rejected_now),
    }


# ── Admin audit log ────────────────────────────────────────────────────────


@router.get("/audit")
async def list_audit(
    page: int = Query(1, ge=1),
    per_page: int = Query(50, ge=1, le=200),
    action: str | None = Query(None, description="Filter by action key"),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    """Paginated admin-action audit log. Most recent first."""
    q = select(AdminAudit).order_by(AdminAudit.created_at.desc())
    count_q = select(func.count(AdminAudit.id))
    if action:
        q = q.where(AdminAudit.action == action)
        count_q = count_q.where(AdminAudit.action == action)
    total = (await db.execute(count_q)).scalar() or 0
    rows = (
        await db.execute(q.offset((page - 1) * per_page).limit(per_page))
    ).scalars().all()
    return {
        "rows": [
            {
                "id": str(r.id),
                "admin_username": r.admin_username,
                "action": r.action,
                "target": r.target,
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
            for r in rows
        ],
        "total": total,
        "page": page,
        "per_page": per_page,
        "total_pages": (total + per_page - 1) // per_page if total else 0,
    }


async def _record_admin_audit(
    db: AsyncSession, action: str, target: dict | None = None
) -> None:
    """Append-only audit row for a privileged admin action.

    The session map only tracks tokens, not which human is logged in —
    but the env-configured admin user is the only identity that can
    issue tokens, so ``settings.admin_username`` is the authoritative
    actor here. If the table doesn't exist yet (dev DB on an old
    schema), swallow the failure rather than poisoning the mutation
    we're trying to log.
    """
    try:
        db.add(
            AdminAudit(
                admin_username=settings.admin_username,
                action=action,
                target=target,
            )
        )
        await db.flush()
    except Exception:  # noqa: BLE001 — auditing is best-effort
        pass


async def _bump_dict_version(db: AsyncSession) -> int:
    """Atomically increment the singleton meta row and return the new value."""
    result = await db.execute(
        text(
            "UPDATE dictionary_meta SET version = version + 1, "
            "updated_at = NOW() WHERE id = 1 RETURNING version"
        )
    )
    new_version = result.scalar()
    if new_version is None:
        # Defensive: dev DB without the seed row. Insert and recurse.
        await db.execute(
            text(
                "INSERT INTO dictionary_meta (id, version) VALUES (1, 1) "
                "ON CONFLICT (id) DO UPDATE SET version = dictionary_meta.version + 1"
            )
        )
        result = await db.execute(select(DictionaryMeta.version))
        new_version = result.scalar() or 1
    return int(new_version)


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


def _coerce_inbound(val: Any) -> Any:
    """Convert a JSON value into something psycopg can bind.

    Lists/dicts are JSON-encoded so they can be inserted into jsonb columns;
    primitive types are passed through unchanged.
    """
    import json

    if isinstance(val, (list, dict)):
        return json.dumps(val)
    return val


async def _assert_table_exists(conn, table_name: str) -> None:
    from fastapi import HTTPException

    check = await conn.execute(
        text(
            "SELECT 1 FROM information_schema.tables "
            "WHERE table_schema='public' AND table_name=:t"
        ),
        {"t": table_name},
    )
    if check.fetchone() is None:
        raise HTTPException(status_code=404, detail="Table not found")


async def _column_names(conn, table_name: str) -> set[str]:
    result = await conn.execute(
        text(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_schema='public' AND table_name=:t"
        ),
        {"t": table_name},
    )
    return {row[0] for row in result.fetchall()}


async def _primary_key_column(conn, table_name: str) -> str | None:
    """Return the name of the single-column PK, or None for composite/no PK."""
    result = await conn.execute(
        text(
            """
            SELECT a.attname
            FROM pg_index i
            JOIN pg_attribute a
              ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = (quote_ident(:t))::regclass AND i.indisprimary
            """
        ),
        {"t": table_name},
    )
    cols = [row[0] for row in result.fetchall()]
    if len(cols) != 1:
        return None
    return cols[0]
