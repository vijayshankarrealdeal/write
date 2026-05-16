"""Snapshot today's recommendation-system metrics so we can diff after the
upcoming engine upgrades land.

Runs five raw-SQL queries against the same DB the API uses and prints a
single compact table. Each metric is computed independently; if one
query fails (table empty, schema mismatch, etc.) we print ``n/a`` for
that row and keep going — the whole point is to capture *whatever* the
current state is, even if some signals haven't started flowing yet.

Re-run this script unchanged after launch and diff the numbers.

Usage:
    cd backend && python -m scripts.recsys_baseline
    # or
    python backend/scripts/recsys_baseline.py
"""
from __future__ import annotations

import asyncio
import logging
import sys
from datetime import datetime, timezone

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from app.database import engine

log = logging.getLogger("scripts.recsys_baseline")


# ---------- queries ------------------------------------------------------

# (a) Personalized CTR (7d) — clicks / impressions over the last week.
_Q_CTR_7D = text(
    """
    SELECT
      COUNT(*) FILTER (WHERE event_type = 'click')::float
        / NULLIF(COUNT(*) FILTER (WHERE event_type = 'impression'), 0) AS ctr_7d,
      COUNT(*) FILTER (WHERE event_type = 'impression') AS impressions_7d,
      COUNT(*) FILTER (WHERE event_type = 'click') AS clicks_7d
    FROM recommendation_events
    WHERE created_at > now() - interval '7 days'
    """
)

# (b) Completion-of-recommended (30d) — share of clicked recs that were
# subsequently completed by the same user.
_Q_COMPLETION_30D = text(
    """
    SELECT
      COUNT(DISTINCT rp.feed_item_id)::float
        / NULLIF(COUNT(DISTINCT re.feed_item_id), 0) AS completion_of_recommended_30d
    FROM recommendation_events re
    LEFT JOIN reading_progress rp
      ON rp.feed_item_id = re.feed_item_id
     AND rp.user_id = re.user_id
     AND rp.completed = true
    WHERE re.event_type = 'click'
      AND re.created_at > now() - interval '30 days'
    """
)

# (c) Repeat-impression rate (14d) — average impressions per (user, item)
# pair. Should sit near 1.0; high values mean the engine is spamming.
_Q_REPEAT_14D = text(
    """
    SELECT AVG(c) AS mean_impressions_per_user_item_14d, MAX(c) AS max_repeats
    FROM (
      SELECT user_id, feed_item_id, COUNT(*) AS c
      FROM recommendation_events
      WHERE event_type = 'impression'
        AND created_at > now() - interval '14 days'
      GROUP BY user_id, feed_item_id
    ) t
    """
)

# (d) Author concentration (7d) — top-5 authors' share of impressions.
_Q_AUTHOR_CONCENTRATION_7D = text(
    """
    WITH author_imps AS (
      SELECT fi.author_id, COUNT(*) AS imps
      FROM recommendation_events re
      JOIN feed_items fi ON fi.id = re.feed_item_id
      WHERE re.event_type = 'impression'
        AND re.created_at > now() - interval '7 days'
      GROUP BY fi.author_id
    ),
    ranked AS (
      SELECT *, ROW_NUMBER() OVER (ORDER BY imps DESC) AS rk FROM author_imps
    )
    SELECT
      COALESCE(
        SUM(imps) FILTER (WHERE rk <= 5)::float / NULLIF(SUM(imps), 0),
        0
      ) AS top5_author_share_7d
    FROM ranked
    """
)

# (e) Followed-author share of feed (7d) — fraction of impressions whose
# author is followed (status='approved') by the impressioned user.
#
# NOTE: this app's `follows` table uses `follower_id` / `followee_id`
# (not `followed_id`), and the approval value is the literal string
# 'approved' (constrained to ('pending','approved')). See
# backend/app/models/follow.py.
_Q_FOLLOWED_SHARE_7D = text(
    """
    SELECT
      COUNT(*) FILTER (WHERE f.id IS NOT NULL)::float
        / NULLIF(COUNT(*), 0) AS followed_author_impression_share_7d
    FROM recommendation_events re
    JOIN feed_items fi ON fi.id = re.feed_item_id
    LEFT JOIN follows f
      ON f.follower_id = re.user_id
     AND f.followee_id = fi.author_id
     AND f.status = 'approved'
    WHERE re.event_type = 'impression'
      AND re.created_at > now() - interval '7 days'
    """
)


# ---------- metric runners ----------------------------------------------


async def _safe_fetch_one(conn: AsyncConnection, label: str, query) -> dict | None:
    """Run a query that returns at most one row. Returns the row as a
    mapping (or None) on success, logs a warning and returns None on
    failure. We never let a single query failure abort the whole
    baseline — partial data is still better than no data."""
    try:
        result = await conn.execute(query)
        row = result.mappings().first()
        return dict(row) if row is not None else None
    except Exception as exc:  # noqa: BLE001 — best-effort snapshot
        log.warning("metric %s failed: %s", label, exc)
        return None


def _fmt_pct(value) -> str:
    if value is None:
        return "n/a"
    return f"{float(value) * 100:.2f}%"


def _fmt_num(value, places: int = 2) -> str:
    if value is None:
        return "n/a"
    return f"{float(value):.{places}f}"


def _fmt_int(value) -> str:
    if value is None:
        return "n/a"
    return f"{int(value)}"


async def _collect_metrics() -> dict[str, dict | None]:
    async with engine.connect() as conn:
        ctr = await _safe_fetch_one(conn, "ctr_7d", _Q_CTR_7D)
        completion = await _safe_fetch_one(conn, "completion_30d", _Q_COMPLETION_30D)
        repeat = await _safe_fetch_one(conn, "repeat_14d", _Q_REPEAT_14D)
        author = await _safe_fetch_one(conn, "author_concentration_7d", _Q_AUTHOR_CONCENTRATION_7D)
        followed = await _safe_fetch_one(conn, "followed_share_7d", _Q_FOLLOWED_SHARE_7D)
    return {
        "ctr": ctr,
        "completion": completion,
        "repeat": repeat,
        "author": author,
        "followed": followed,
    }


def _render(metrics: dict[str, dict | None]) -> str:
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines: list[str] = []
    lines.append(f"=== recsys baseline: {now_iso} ===")
    lines.append("")

    ctr = metrics["ctr"] or {}
    ctr_pct = _fmt_pct(ctr.get("ctr_7d"))
    clicks = _fmt_int(ctr.get("clicks_7d"))
    imps = _fmt_int(ctr.get("impressions_7d"))
    if metrics["ctr"] is None:
        lines.append(f"personalized CTR (7d):                {ctr_pct}")
    else:
        lines.append(
            f"personalized CTR (7d):                {ctr_pct}   "
            f"({clicks} clicks / {imps} impressions)"
        )

    completion = metrics["completion"] or {}
    lines.append(
        f"completion of recommended (30d):     "
        f"{_fmt_pct(completion.get('completion_of_recommended_30d'))}"
    )

    repeat = metrics["repeat"] or {}
    mean_rep = _fmt_num(repeat.get("mean_impressions_per_user_item_14d"))
    max_rep = _fmt_int(repeat.get("max_repeats"))
    lines.append(
        f"mean impressions per (user,item) 14d:  {mean_rep}   (max {max_rep})"
    )

    author = metrics["author"] or {}
    lines.append(
        f"top-5 author share of impressions 7d:  "
        f"{_fmt_pct(author.get('top5_author_share_7d'))}"
    )

    followed = metrics["followed"] or {}
    lines.append(
        f"followed-author impression share 7d:   "
        f"{_fmt_pct(followed.get('followed_author_impression_share_7d'))}"
    )

    lines.append("")
    lines.append("note: re-run this script post-launch and diff the values.")
    return "\n".join(lines)


async def _main_async() -> int:
    try:
        metrics = await _collect_metrics()
    finally:
        # `engine` is a module-level singleton imported from
        # app.database; dispose so the asyncio loop closes cleanly when
        # the script exits.
        await engine.dispose()
    print(_render(metrics))
    return 0


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    return asyncio.run(_main_async())


if __name__ == "__main__":
    sys.exit(main())
