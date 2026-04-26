"""Backfill embeddings for already-published feed items.

Idempotent: skips rows where `embedding IS NOT NULL` (unless `--force`).
Walks the catalogue in batches of 50, sleeps `--pause-sec` between
batches to respect Azure OpenAI rate limits.

Usage:
    python -m backend.scripts.backfill_embeddings
    python -m backend.scripts.backfill_embeddings --batch 50 --pause-sec 1.0
    python -m backend.scripts.backfill_embeddings --force         # re-embed everything
"""
from __future__ import annotations

import argparse
import asyncio
import logging

from sqlalchemy import select

from app.ai.embeddings import embed_many
from app.database import async_session
from app.models.feed_item import FeedItem

log = logging.getLogger("scripts.backfill_embeddings")


async def _run(batch_size: int, pause_sec: float, force: bool) -> None:
    total_ok = 0
    total_seen = 0
    last_id = None
    while True:
        async with async_session() as session:
            stmt = (
                select(FeedItem.id)
                .where(FeedItem.is_draft.is_(False))
                .order_by(FeedItem.id)
                .limit(batch_size)
            )
            if not force:
                stmt = stmt.where(FeedItem.embedding.is_(None))
            if last_id is not None:
                stmt = stmt.where(FeedItem.id > last_id)
            rows = (await session.execute(stmt)).scalars().all()

        if not rows:
            break

        ok, seen = await embed_many(rows, force=force)
        total_ok += ok
        total_seen += seen
        last_id = rows[-1]
        log.info("batch done: %s/%s embedded (running %s/%s)", ok, seen, total_ok, total_seen)

        if pause_sec > 0:
            await asyncio.sleep(pause_sec)

    log.info("backfill complete: %s embedded out of %s seen", total_ok, total_seen)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch", type=int, default=50)
    parser.add_argument("--pause-sec", type=float, default=1.0)
    parser.add_argument("--force", action="store_true", help="re-embed rows that already have one")
    args = parser.parse_args()
    asyncio.run(_run(args.batch, args.pause_sec, args.force))


if __name__ == "__main__":
    main()
