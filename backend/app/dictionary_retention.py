"""Retention sweep for raw dictionary submissions.

Privacy policy commits to anonymising raw user → word submissions at
the 12-month mark. This module owns the actual sweep, called from
both:

- the FastAPI lifespan (a once-a-day background task — see app.main),
- a one-shot CLI script (``backend/scripts/dictionary_retention.py``)
  the ops team can fire manually.

The sweep does not delete rows. It NULLs ``user_id`` on submissions
older than the configured window so the audit trail of *what words
were submitted* is preserved while the *who submitted them* link is
severed. ``dictionary_submissions.user_id`` is nullable for exactly
this reason (see migration 20260504_02).
"""
from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone

from sqlalchemy import update

from app.config import settings
from app.database import async_session
from app.logger import get_logger
from app.models.dictionary import DictionarySubmission

log = get_logger("app.dictionary_retention")

# How often the in-process sweeper wakes up. Daily is plenty — the
# privacy commitment is a 12-month boundary, not a real-time one.
_SWEEP_INTERVAL_SECONDS = 24 * 60 * 60


async def run_once() -> int:
    """Run a single retention sweep. Returns rows anonymised."""
    days = settings.dictionary_submission_retention_days
    if days <= 0:
        return 0
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    async with async_session() as session:
        result = await session.execute(
            update(DictionarySubmission)
            .where(
                DictionarySubmission.created_at < cutoff,
                DictionarySubmission.user_id.isnot(None),
            )
            .values(user_id=None)
        )
        await session.commit()
        scrubbed = result.rowcount or 0
    if scrubbed:
        log.info(
            "dictionary retention sweep: anonymised %d submissions older than %d days",
            scrubbed,
            days,
        )
    return scrubbed


async def run_forever() -> None:
    """Daily-cadence sweep loop. Started from the FastAPI lifespan.

    Wraps each iteration in try/except so a transient DB blip on one
    sweep doesn't terminate the loop — a kill of this task would only
    resume on the next process restart.
    """
    while True:
        try:
            await run_once()
        except Exception as e:  # noqa: BLE001
            log.exception("dictionary retention sweep failed: %s", e)
        await asyncio.sleep(_SWEEP_INTERVAL_SECONDS)
