"""User-facing dictionary endpoints.

- ``POST /api/dictionary/submit`` — record a word the user marked
  "Add to dictionary". Per-user dedup; the word is **not** added to the
  global dictionary here. An admin must run the AI merge first.
- ``GET /api/dictionary/snapshot?since=N`` — return the delta of the
  global merged dictionary since version N. The fetch payload carries
  no user text — only an integer version number out, a delta of
  word strings back.

Submitted words leave the device; snapshot fetches do not. This is the
"backend only sees a version number, not the user's prose" property.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.config import settings
from app.database import get_db
from app.models.dictionary import (
    DictionaryMeta,
    DictionaryRemoval,
    DictionarySubmission,
    DictionaryWord,
)
from app.models.user import User
from app.schemas.dictionary import (
    SnapshotResponse,
    SubmitWordRequest,
    SubmitWordResponse,
)

router = APIRouter(prefix="/api/dictionary", tags=["dictionary"])


@router.post("/submit", response_model=SubmitWordResponse)
async def submit_word(
    body: SubmitWordRequest,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Queue a word for the next admin merge.

    Idempotent per (user, word, language). Returns ``already_global``
    when the word is already in the merged dictionary so the client can
    skip the noise of a "queued" toast for words it shouldn't have
    flagged in the first place.
    """
    word = body.word.strip().lower()
    lang = body.language.strip().lower()

    # Already in the global dict — nothing to do.
    existing_global = await db.execute(
        select(DictionaryWord.word).where(
            DictionaryWord.word == word, DictionaryWord.language == lang
        )
    )
    if existing_global.scalar_one_or_none() is not None:
        return SubmitWordResponse(status="already_global")

    # Daily per-user cap on unique submissions. Dedup blocks same-word
    # repeats but a unique-word flood would still poison the merge
    # queue — count what's been queued in the last 24h and bounce the
    # request once the cap is hit.
    cap = settings.dictionary_submit_daily_cap
    if cap > 0:
        since = datetime.now(timezone.utc) - timedelta(days=1)
        recent = (
            await db.execute(
                select(func.count(DictionarySubmission.id)).where(
                    DictionarySubmission.user_id == user.id,
                    DictionarySubmission.created_at >= since,
                )
            )
        ).scalar() or 0
        if recent >= cap:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail=(
                    f"Daily submission cap reached ({cap}/day). Try again "
                    "tomorrow."
                ),
            )

    # Per-user dedup via INSERT ... ON CONFLICT DO NOTHING. Cheaper
    # than a SELECT-then-INSERT round-trip and race-safe.
    stmt = (
        pg_insert(DictionarySubmission)
        .values(user_id=user.id, word=word, language=lang)
        .on_conflict_do_nothing(
            constraint="uq_dict_sub_user_word"
        )
        .returning(DictionarySubmission.id)
    )
    result = await db.execute(stmt)
    inserted = result.scalar_one_or_none()
    await db.commit()

    return SubmitWordResponse(
        status="queued" if inserted is not None else "duplicate"
    )


@router.get("/snapshot", response_model=SnapshotResponse)
async def snapshot(
    since: int = Query(default=0, ge=0),
    language: str = Query(default="en", min_length=2, max_length=8),
    _user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Return additions + removals since the client's cached version.

    Wire shape: ``{version, added: [...], removed: [...]}``. When the
    client is already up to date both lists come back empty. The
    request body carries no user prose — just a version integer.
    """
    meta_row = await db.execute(select(DictionaryMeta.version))
    current_version = meta_row.scalar_one_or_none() or 0

    if since >= current_version:
        return SnapshotResponse(version=current_version, added=[], removed=[])

    added_rows = await db.execute(
        select(DictionaryWord.word).where(
            DictionaryWord.added_in_version > since,
            DictionaryWord.language == language,
        )
    )
    removed_rows = await db.execute(
        select(DictionaryRemoval.word).where(
            DictionaryRemoval.removed_in_version > since,
            DictionaryRemoval.language == language,
        )
    )

    return SnapshotResponse(
        version=current_version,
        added=[r for (r,) in added_rows.all()],
        removed=[r for (r,) in removed_rows.all()],
    )
