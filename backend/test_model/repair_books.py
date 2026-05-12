"""Repair pass over already-ingested books.

Applies two cheap, deterministic fixes to every Writing published under
the editorial "inkspace" identity, without re-running the LLM pipeline:

  1. **Byline** — FeedItem.author starts life as the publishing user's
     display name ("inkspace"). Replace it with the writing's actual
     author (Jane Austen, Mark Twain, …). Backfills Writing.author from
     the curated `lookup_known_author(title)` map for the 12 Gutenberg
     classics that lack a `dc.creator` meta tag.

  2. **Chapter bodies** — strip `[Copyright YYYY by X.]` and lone
     `[Illustration]` ops that leaked through the HTML→markdown
     conversion (most visible in 19th-century editions with engraved
     plates, e.g. the Hugh Thomson edition of Pride and Prejudice).

Idempotent: re-running on a clean DB is a no-op. Prints a per-book
diff so the operator can sanity-check before any rows commit.

Usage:

    python repair_books.py            # apply repairs to every Writing
    python repair_books.py --dry-run  # report what would change
"""

from __future__ import annotations

import argparse
import asyncio
import re
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_BACKEND_ROOT = _HERE.parent
if str(_BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(_BACKEND_ROOT))

from sqlalchemy import select  # noqa: E402
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine  # noqa: E402

from app.config import settings  # noqa: E402
from app.models.feed_item import FeedItem  # noqa: E402
from app.models.section import Section  # noqa: E402
from app.models.user import User  # noqa: E402
from app.models.writing import Writing  # noqa: E402
from book_ingest.db_publish import INKSPACE_NAME  # noqa: E402
from book_ingest.known_authors import lookup_known_author  # noqa: E402


# Bracketed `[Copyright 1894 by George Allen.]` artifacts that leaked
# through HTML→markdown rendering. Mirrors (but is broader than) the
# pattern added to `boilerplate.py` — we only run this against
# already-stored ops, so we can be aggressive about whitespace and
# the optional surrounding asterisks (markdown italics).
_COPYRIGHT_LINE_RE = re.compile(
    r"\[?\s*\*?\s*copyright\s+\d{4}\s+by\b[^\]\n]*\*?\s*\]?",
    re.IGNORECASE,
)
# Lone `[Illustration]` / `[Illustration:]` captions left over after we
# drop the underlying `<img>`.
_ILLUSTRATION_LINE_RE = re.compile(
    r"\[?\s*\*?\s*illustration\s*[:.]?\s*\*?\s*\]?",
    re.IGNORECASE,
)


def _make_engine():
    return create_async_engine(settings.database_url, future=True)


def _strip_artifacts(text: str) -> str:
    """Drop bracketed copyright + illustration lines from a Quill insert.

    Operates line-by-line so we only remove standalone artifact lines —
    a sentence that happens to mention the word "illustration" mid-
    paragraph survives intact.
    """
    if not text or not isinstance(text, str):
        return text
    out: list[str] = []
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped:
            out.append(line)
            continue
        if _COPYRIGHT_LINE_RE.fullmatch(stripped):
            continue
        if _ILLUSTRATION_LINE_RE.fullmatch(stripped):
            continue
        out.append(line)
    cleaned = "\n".join(out)
    # Collapse 3+ blank lines (we may have just emptied one) back to 2,
    # matching the rest of the pipeline's paragraph-break convention.
    return re.sub(r"\n{3,}", "\n\n", cleaned)


def _clean_section_ops(ops: list | None) -> tuple[list | None, int]:
    """Return (new_ops, stripped_count). `stripped_count` counts ops
    whose insert lost characters or vanished entirely."""
    if not isinstance(ops, list):
        return ops, 0
    new_ops: list = []
    stripped = 0
    for op in ops:
        if not isinstance(op, dict):
            new_ops.append(op)
            continue
        ins = op.get("insert")
        if isinstance(ins, str):
            cleaned = _strip_artifacts(ins)
            if cleaned != ins:
                stripped += 1
                if cleaned.strip() == "":
                    # Drop the op entirely if cleaning emptied it.
                    continue
                new_op = dict(op)
                new_op["insert"] = cleaned
                new_ops.append(new_op)
                continue
        new_ops.append(op)
    return new_ops, stripped


async def _repair_one_writing(
    db: AsyncSession,
    *,
    writing: Writing,
    inkspace_user_id,
    dry_run: bool,
) -> dict:
    """Apply byline + body repairs to one writing. Returns a per-book
    report dict the caller logs."""
    report: dict = {
        "writing_id": str(writing.id),
        "title": writing.title,
        "old_author": writing.author,
        "new_author": writing.author,
        "feed_byline_updated": False,
        "sections_touched": 0,
        "ops_stripped": 0,
    }

    # 1) Byline. If Writing.author still reads as the editorial identity
    #    ("inkspace") or is empty, try the curated title→author map.
    desired_author = (writing.author or "").strip()
    if desired_author.lower() == INKSPACE_NAME or not desired_author:
        fallback = lookup_known_author(writing.title)
        if fallback:
            desired_author = fallback

    if desired_author and desired_author != (writing.author or ""):
        report["new_author"] = desired_author
        if not dry_run:
            writing.author = desired_author

    # 2) FeedItem.author — if the FeedItem still bylines the publishing
    #    identity, switch it to whatever the Writing's author now reads
    #    as. We only touch feed items whose publisher IS the inkspace
    #    user; author-published writings stay untouched.
    if desired_author:
        result = await db.execute(
            select(FeedItem).where(FeedItem.writing_id == writing.id)
        )
        feed_item = result.scalar_one_or_none()
        if feed_item is not None and feed_item.author_id == inkspace_user_id:
            if (feed_item.author or "").strip() != desired_author:
                report["feed_byline_updated"] = True
                if not dry_run:
                    feed_item.author = desired_author

    # 3) Section bodies — strip bracketed copyright / illustration lines.
    sections = (
        await db.execute(
            select(Section).where(Section.writing_id == writing.id)
        )
    ).scalars().all()
    for section in sections:
        new_ops, stripped = _clean_section_ops(section.content)
        if stripped:
            report["sections_touched"] += 1
            report["ops_stripped"] += stripped
            if not dry_run:
                # Reassign so SQLAlchemy detects the JSONB change. In-place
                # list mutation on a JSONB column isn't picked up by the
                # session's change tracking.
                section.content = new_ops

    return report


async def _run(dry_run: bool) -> None:
    engine = _make_engine()
    Session = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)

    async with Session() as db:
        inkspace_user = (
            await db.execute(select(User).where(User.name == INKSPACE_NAME))
        ).scalar_one_or_none()
        if inkspace_user is None:
            print(
                f"[repair] no user named {INKSPACE_NAME!r} found — nothing to do."
            )
            return

        # Repair every Writing the inkspace identity owns. These are the
        # batch-ingested classics; author-published writings (different
        # owner) are untouched.
        writings = (
            await db.execute(
                select(Writing).where(Writing.user_id == inkspace_user.id)
            )
        ).scalars().all()

        print(
            f"[repair] {'(dry-run) ' if dry_run else ''}scanning "
            f"{len(writings)} writing(s) owned by {INKSPACE_NAME!r}…"
        )

        total_byline = 0
        total_sections = 0
        total_ops = 0
        for w in writings:
            report = await _repair_one_writing(
                db,
                writing=w,
                inkspace_user_id=inkspace_user.id,
                dry_run=dry_run,
            )
            if (
                report["feed_byline_updated"]
                or report["new_author"] != report["old_author"]
                or report["sections_touched"]
            ):
                old = report["old_author"] or "(none)"
                new = report["new_author"] or "(none)"
                print(
                    f"  {report['title']!r:60.60} "
                    f"byline {old!r} → {new!r}"
                    f"  sections={report['sections_touched']}"
                    f"  ops={report['ops_stripped']}"
                )
                if report["feed_byline_updated"]:
                    total_byline += 1
                total_sections += report["sections_touched"]
                total_ops += report["ops_stripped"]

        if dry_run:
            print(
                f"[repair] dry-run summary — would update {total_byline} "
                f"feed byline(s), {total_sections} section(s), strip "
                f"{total_ops} op(s)."
            )
            return
        await db.commit()
        print(
            f"[repair] committed — updated {total_byline} feed byline(s), "
            f"cleaned {total_sections} section(s), stripped {total_ops} op(s)."
        )


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Backfill author bylines + strip copyright/illustration "
        "leftovers on already-ingested books."
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Report changes without writing to the DB.",
    )
    return p.parse_args()


if __name__ == "__main__":
    args = _parse_args()
    asyncio.run(_run(dry_run=args.dry_run))
