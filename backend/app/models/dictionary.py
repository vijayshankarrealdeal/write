"""Personal-dictionary harvesting + global merged dictionary.

Architecture (matches Hunspell-based editors, iOS, Grammarly offline):

1. The Flutter client ships a **base dictionary** in its assets bundle —
   the bulk of the words a writer will ever encounter, so cold-start
   spellcheck works offline.
2. On app launch, the client GETs ``/api/dictionary/snapshot?since=N``,
   passing the last version number it has cached. Backend returns the
   *delta* (words added or removed since N) plus the new version. No
   user prose ever crosses the wire on this path — only a version
   number out, a delta back.
3. Live updates ride the existing SSE hub on a ``dictionary`` channel:
   ``{"type":"dictionary.updated","version":N+1}`` triggers the client
   to fetch the next delta immediately.

Three tables, plus a singleton meta row for the current version:

- ``dictionary_submissions`` — raw, unvetted words a user tapped "Add
  to dictionary" on. Per-user dedup. Status flips to ``approved`` /
  ``rejected`` when an admin runs the AI merge. **Never** consulted by
  the spell-check engine — keeps a single noisy user from making a
  typo silently global.
- ``dictionary_words`` — the curated global dictionary. Each row carries
  ``added_in_version`` so deltas can be served cheaply.
- ``dictionary_removals`` — a tombstone log so removed words can be
  pulled out of client caches via the same delta path.
- ``dictionary_meta`` — singleton row with the current version. Bumped
  on every merge / direct admin add / removal.
"""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    DateTime,
    ForeignKey,
    Index,
    String,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDMixin


class DictionarySubmission(UUIDMixin, Base):
    __tablename__ = "dictionary_submissions"

    # Nullable so the daily retention sweep can anonymise rows older
    # than the configured window (see backend/scripts/dictionary_retention.py
    # and the scheduled task in app.main.lifespan). The privacy policy
    # commits to scrubbing user_id at the 12-month mark; the sweep
    # honours that automatically.
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    # Stored lower-cased so the per-user unique constraint also serves
    # as case-insensitive dedup.
    word: Mapped[str] = mapped_column(String(64), nullable=False)
    language: Mapped[str] = mapped_column(String(8), nullable=False, default="en")
    # pending | approved | rejected
    status: Mapped[str] = mapped_column(
        String(16), nullable=False, default="pending", index=True
    )
    # Optional one-line note set by the AI merge pass — useful for
    # admin review when a word was rejected ("looks like a typo of
    # 'definitely'").
    note: Mapped[str | None] = mapped_column(String(256))

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), index=True
    )
    processed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        UniqueConstraint(
            "user_id", "word", "language", name="uq_dict_sub_user_word"
        ),
    )


class DictionaryWord(Base):
    """One row per merged-and-accepted global dictionary word."""

    __tablename__ = "dictionary_words"

    word: Mapped[str] = mapped_column(String(64), primary_key=True)
    language: Mapped[str] = mapped_column(
        String(8), primary_key=True, default="en"
    )
    # 'merged' (came in via user submissions + AI accept) | 'curated'
    # (added by an admin directly).
    source: Mapped[str] = mapped_column(String(16), nullable=False, default="merged")
    # How many distinct users had submitted this word at merge time —
    # captured for transparency in the admin viewer.
    submission_count: Mapped[int] = mapped_column(
        BigInteger, nullable=False, default=1
    )
    # Version number this word landed in. Snapshot deltas filter on
    # ``added_in_version > since``, so this column is what makes the
    # cache-cheap delta protocol possible.
    added_in_version: Mapped[int] = mapped_column(
        BigInteger, nullable=False, index=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (
        Index("ix_dictionary_words_lang", "language"),
    )


class DictionaryRemoval(Base):
    """Tombstone for a word pulled from the global dictionary.

    The snapshot delta endpoint returns these so client caches drop the
    word too. Without tombstones a removal would never propagate to
    devices that are already up-to-date — they'd carry the word forever.
    """

    __tablename__ = "dictionary_removals"

    word: Mapped[str] = mapped_column(String(64), primary_key=True)
    language: Mapped[str] = mapped_column(
        String(8), primary_key=True, default="en"
    )
    removed_in_version: Mapped[int] = mapped_column(
        BigInteger, nullable=False, index=True
    )
    removed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class DictionaryMeta(Base):
    """Singleton row holding the current dict version.

    Bumped on every merge / direct admin add / removal. Clients pass
    ``since=<their_version>`` to ``GET /api/dictionary/snapshot`` and
    skip downloading words when nothing has changed.
    """

    __tablename__ = "dictionary_meta"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, default=1)
    version: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
