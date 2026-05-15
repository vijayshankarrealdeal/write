"""Audiobook artifacts on sections + cover image on feed_items.

Adds the columns needed to serve TTS-generated audio with per-word
highlighting in the reader:

* ``sections.audio_url`` — MinIO public URL to the chapter MP3 (32 kbps
  mono, ~3-4 MB / 10 min). Streamed directly by the client; the server
  does not proxy the bytes.
* ``sections.audio_words_url`` — MinIO URL to the sibling
  ``*.words.json`` produced by faster-whisper word alignment. Schema:
  ``{"wav": "...", "duration": float_seconds, "words": [{"w": str,
  "start": float_seconds, "end": float_seconds}, ...]}``.
* ``sections.audio_duration_s`` — duration in seconds (denormalised
  from the words.json so the client can show the scrubber without
  needing to fetch the timings first).
* ``sections.voice_name`` — Supertonic preset (M1..M5 / F1..F5) used
  for narration. Display only; the client doesn't need to know which
  voice was used to play the audio, but it lets the audio-player page
  show "Narrated by M3 (warm)".
* ``feed_items.cover_image_url`` — book cover (the "1989 Deluxe"
  square in the audio-player page). The feed already carries an
  ``image_url`` for the feed-card thumbnail; this one is the big
  square cover used in the dedicated audio view.

All columns are nullable so existing rows keep working unchanged —
only books imported through the new ``/api/admin/books/import``
endpoint will have these set.

Revision ID: 20260515_01
Revises: 20260514_01
Create Date: 2026-05-15
"""
from __future__ import annotations

from alembic import op


revision = "20260515_01"
down_revision = "20260514_01"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE sections "
        "ADD COLUMN IF NOT EXISTS audio_url TEXT, "
        "ADD COLUMN IF NOT EXISTS audio_words_url TEXT, "
        "ADD COLUMN IF NOT EXISTS audio_duration_s DOUBLE PRECISION, "
        "ADD COLUMN IF NOT EXISTS voice_name VARCHAR(8)"
    )
    op.execute(
        "ALTER TABLE feed_items "
        "ADD COLUMN IF NOT EXISTS cover_image_url TEXT"
    )
    # Partial index so the audio-discovery query ("books that have any
    # narrated chapter") only walks rows where audio actually exists.
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_sections_has_audio "
        "ON sections (writing_id) WHERE audio_url IS NOT NULL"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_sections_has_audio")
    op.execute(
        "ALTER TABLE sections "
        "DROP COLUMN IF EXISTS audio_url, "
        "DROP COLUMN IF EXISTS audio_words_url, "
        "DROP COLUMN IF EXISTS audio_duration_s, "
        "DROP COLUMN IF EXISTS voice_name"
    )
    op.execute("ALTER TABLE feed_items DROP COLUMN IF EXISTS cover_image_url")
