"""Recompute the `feed_facets` cache table.

Cron: run hourly (or whatever cadence operations decide). The router
treats rows older than 48h as missing and falls back to the live
`array_agg + unnest` query, so the cache going stale degrades quietly
rather than serving stale data.

Computes top facet counts per kind (`genre`, `tag`, `writing_type`)
over published items only and replaces the rows in a single
transaction. The atomic swap means readers either see the previous
generation in full or the new generation in full — never a partial
mid-refresh state.

Usage:
    python -m backend.scripts.refresh_feed_facets [--limit N]
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import sys

from sqlalchemy import text

from app.database import engine

# Number of rows we keep per kind. Matches the router's `_FACET_LIMIT`
# default — top 32 buckets is enough for the chip strip + the long
# tail in the "More filters" sheet.
DEFAULT_LIMIT = 32

# Each (column_name, kind_label) pair. Column names are inlined into
# the SQL because they're a fixed enum, not user input.
_KINDS: tuple[tuple[str, str], ...] = (
    ("genres", "genre"),
    ("tags", "tag"),
    ("writing_types", "writing_type"),
)


log = logging.getLogger("refresh_feed_facets")


async def refresh(limit: int) -> dict[str, int]:
    counts: dict[str, int] = {}
    async with engine.begin() as conn:
        for col, kind in _KINDS:
            # Per-kind: drop the old generation, recompute the top
            # `limit` buckets, insert. All inside the same transaction
            # so the table stays consistent for readers.
            await conn.execute(
                text("DELETE FROM feed_facets WHERE kind = :kind").bindparams(kind=kind)
            )
            stmt = text(
                f"""
                INSERT INTO feed_facets (kind, value, count, refreshed_at)
                SELECT :kind, value, COUNT(*)::INT AS count, NOW()
                FROM (
                    SELECT UNNEST({col}) AS value FROM feed_items WHERE is_draft = FALSE
                ) sub
                WHERE value IS NOT NULL AND value <> ''
                GROUP BY value
                ORDER BY count DESC
                LIMIT :lim
                """
            ).bindparams(kind=kind, lim=limit)
            res = await conn.execute(stmt)
            counts[kind] = res.rowcount or 0
    return counts


def _parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Refresh feed_facets cache.")
    p.add_argument(
        "--limit",
        type=int,
        default=DEFAULT_LIMIT,
        help=f"Top-N rows per kind (default {DEFAULT_LIMIT}).",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    counts = asyncio.run(refresh(args.limit))
    for kind, n in counts.items():
        log.info("feed_facets refreshed: kind=%s rows=%d", kind, n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
