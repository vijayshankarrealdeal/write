"""End-to-end integration test for the analytics ingest path.

Boots a throwaway Postgres in Docker via `testcontainers`, runs the
real Alembic migration, then hits `POST /api/analytics/events` twice
through the FastAPI app — one anonymous batch, one authenticated batch
with the same `client_id` — and asserts the second call backfills the
prior anonymous rows with `user_id`.

Skip behaviour:
- If `testcontainers[postgres]` isn't installed (production
  `requirements.txt` doesn't pull it in — see `requirements-dev.txt`),
  every test in this module is skipped.
- If the Docker daemon isn't reachable when the container fixture
  spins up, every test in this module is skipped. We never fail the
  suite for environment reasons.

Run locally with:
    pip install -r backend/requirements.txt -r backend/requirements-dev.txt
    cd backend && pytest tests/test_analytics_integration.py -v
"""
from __future__ import annotations

import importlib
import os
import uuid
from datetime import datetime, timezone

import pytest

try:  # graceful skip if dev deps aren't installed
    from testcontainers.postgres import PostgresContainer

    _HAS_TESTCONTAINERS = True
except ImportError:  # pragma: no cover
    PostgresContainer = None  # type: ignore[assignment]
    _HAS_TESTCONTAINERS = False


pytestmark = pytest.mark.skipif(
    not _HAS_TESTCONTAINERS,
    reason="testcontainers[postgres] not installed (see backend/requirements-dev.txt)",
)


@pytest.fixture(scope="module")
def pg_container():
    """Spin up a Postgres container and tear it down after the module.

    Skips the whole module if Docker isn't available — testcontainers
    raises a generic exception on socket failure that we catch here so
    contributors without Docker don't see a noisy failure.
    """
    try:
        container = PostgresContainer("postgres:16-alpine")
        container.start()
    except Exception as e:  # pragma: no cover — env-dependent
        pytest.skip(f"Docker unavailable for testcontainers: {e}")
    try:
        yield container
    finally:
        container.stop()


@pytest.fixture(scope="module")
def app_with_db(pg_container):
    """Apply Alembic, then build a fresh FastAPI app pointed at the
    test database.

    `app.config.settings` reads `DATABASE_URL` at import time, so we
    set the env var, then reload the modules whose globals have
    already captured the previous value (config, database, models —
    the routers transitively re-import as a result of `app.main`'s
    import chain).
    """
    sync_url = pg_container.get_connection_url()  # postgresql+psycopg2://...
    # Strip whichever sync driver testcontainers picked and force asyncpg.
    if sync_url.startswith("postgresql+psycopg2://"):
        async_url = sync_url.replace("postgresql+psycopg2://", "postgresql+asyncpg://")
    elif sync_url.startswith("postgresql://"):
        async_url = "postgresql+asyncpg://" + sync_url[len("postgresql://"):]
    else:
        async_url = sync_url

    os.environ["DATABASE_URL"] = async_url

    # JWT_SECRET is enforced by Settings — match conftest.py's pattern
    # so config validation passes even if conftest hasn't already run.
    os.environ.setdefault(
        "JWT_SECRET",
        "test-secret-not-for-production-padded-to-meet-32-char-min-length",
    )
    os.environ.setdefault("ADMIN_USERNAME", "test-admin")
    os.environ.setdefault("ADMIN_PASSWORD", "test-admin-password")

    # Re-import the modules that captured DATABASE_URL at import time.
    import app.config
    importlib.reload(app.config)
    import app.database
    importlib.reload(app.database)

    # Run the migration synchronously through Alembic's CLI machinery
    # so we apply exactly what production applies.
    from alembic import command
    from alembic.config import Config

    here = os.path.dirname(os.path.abspath(__file__))
    backend_dir = os.path.abspath(os.path.join(here, ".."))
    alembic_cfg = Config(os.path.join(backend_dir, "alembic.ini"))
    alembic_cfg.set_main_option("script_location", os.path.join(backend_dir, "alembic"))
    alembic_cfg.set_main_option("sqlalchemy.url", async_url)
    command.upgrade(alembic_cfg, "head")

    # Now bring the app up. main imports models + routers; config and
    # database have already been reloaded above, so the engine bound
    # to the lifespan points at the test container.
    import app.main
    importlib.reload(app.main)
    return app.main.app


@pytest.fixture
def client(app_with_db):
    from fastapi.testclient import TestClient

    return TestClient(app_with_db)


@pytest.fixture
async def authed_user(app_with_db):
    """Create a user directly via the database and mint a JWT for it,
    so the integration test doesn't depend on the registration flow
    landing first. Yields (user_id, access_token)."""
    from sqlalchemy import select

    import app.database as db_mod
    from app.auth.jwt import create_access_token
    from app.models.user import User

    user_email = f"probe-{uuid.uuid4().hex[:8]}@example.com"
    async with db_mod.async_session() as session:
        user = User(email=user_email, name="probe")
        session.add(user)
        await session.commit()
        await session.refresh(user)
        user_id = user.id

    token = create_access_token(user_id)
    yield user_id, token

    # Cleanup: drop the user and any analytics rows tied to them.
    from sqlalchemy import delete

    from app.models.analytics import AnalyticsEvent

    async with db_mod.async_session() as session:
        await session.execute(
            delete(AnalyticsEvent).where(AnalyticsEvent.user_id == user_id)
        )
        await session.execute(delete(User).where(User.id == user_id))
        await session.commit()


def _event(client_id: str, event_name: str) -> dict:
    return {
        "client_id": client_id,
        "session_id": "test-session",
        "event_name": event_name,
        "client_ts": datetime.now(tz=timezone.utc).isoformat(),
        "properties": {"src": "integration_test"},
    }


@pytest.mark.asyncio
async def test_anonymous_then_authed_batch_stitches_user_id(client, authed_user):
    user_id, token = authed_user
    cid = f"cid-{uuid.uuid4().hex[:12]}"

    # 1. Anonymous batch — three events from this client_id.
    resp = client.post(
        "/api/analytics/events",
        json={
            "events": [
                _event(cid, "auth_login_viewed"),
                _event(cid, "auth_login_submitted"),
                _event(cid, "screen_viewed"),
            ]
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["accepted"] == 3
    assert body["stitched_user_id"] is None
    assert body["stitched_count"] == 0

    # 2. Authenticated batch with the same client_id — backend should
    #    backfill all three prior rows.
    resp = client.post(
        "/api/analytics/events",
        headers={"Authorization": f"Bearer {token}"},
        json={"events": [_event(cid, "auth_login_succeeded")]},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["accepted"] == 1
    assert body["stitched_user_id"] == str(user_id)
    assert body["stitched_count"] == 3, (
        "expected the three anonymous rows to attach onto user_id"
    )

    # 3. Direct DB check — every row keyed on this client_id must now
    #    point at the user.
    from sqlalchemy import select

    import app.database as db_mod
    from app.models.analytics import AnalyticsEvent

    async with db_mod.async_session() as session:
        rows = (
            await session.execute(
                select(AnalyticsEvent.event_name, AnalyticsEvent.user_id)
                .where(AnalyticsEvent.client_id == cid)
                .order_by(AnalyticsEvent.server_ts)
            )
        ).all()

    assert len(rows) == 4
    for event_name, row_user_id in rows:
        assert row_user_id == user_id, (
            f"row {event_name!r} not stitched (user_id={row_user_id})"
        )

    # 4. A subsequent authed batch is a no-op for stitching (idempotent).
    resp = client.post(
        "/api/analytics/events",
        headers={"Authorization": f"Bearer {token}"},
        json={"events": [_event(cid, "screen_viewed")]},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["accepted"] == 1
    assert body["stitched_count"] == 0, "second authed batch shouldn't restitch"
