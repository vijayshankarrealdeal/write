"""Personal dictionary harvest + global merged dictionary.

Revision ID: 20260504_01
Revises: 20260502_07
Create Date: 2026-05-04

Three tables (submissions, merged words, removal tombstones) plus a
singleton meta row holding the dictionary version. Snapshot clients
pass ``since=<version>`` and receive only deltas, so the wire payload
shrinks to a few bytes when nothing has changed.

Idempotent (``IF NOT EXISTS``) so dev DBs that came up via the
lifespan ``create_all`` path still pick up the indexes.
"""
from __future__ import annotations

from alembic import op


revision = "20260504_01"
down_revision = "20260502_07"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS dictionary_submissions (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            word VARCHAR(64) NOT NULL,
            language VARCHAR(8) NOT NULL DEFAULT 'en',
            status VARCHAR(16) NOT NULL DEFAULT 'pending',
            note VARCHAR(256),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            processed_at TIMESTAMPTZ,
            CONSTRAINT uq_dict_sub_user_word UNIQUE (user_id, word, language)
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_dict_sub_user "
        "ON dictionary_submissions (user_id)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_dict_sub_status "
        "ON dictionary_submissions (status)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_dict_sub_created "
        "ON dictionary_submissions (created_at)"
    )

    op.execute(
        """
        CREATE TABLE IF NOT EXISTS dictionary_words (
            word VARCHAR(64) NOT NULL,
            language VARCHAR(8) NOT NULL DEFAULT 'en',
            source VARCHAR(16) NOT NULL DEFAULT 'merged',
            submission_count BIGINT NOT NULL DEFAULT 1,
            added_in_version BIGINT NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (word, language)
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_dictionary_words_lang "
        "ON dictionary_words (language)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_dictionary_words_added_in_version "
        "ON dictionary_words (added_in_version)"
    )

    op.execute(
        """
        CREATE TABLE IF NOT EXISTS dictionary_removals (
            word VARCHAR(64) NOT NULL,
            language VARCHAR(8) NOT NULL DEFAULT 'en',
            removed_in_version BIGINT NOT NULL,
            removed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (word, language)
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_dictionary_removals_version "
        "ON dictionary_removals (removed_in_version)"
    )

    op.execute(
        """
        CREATE TABLE IF NOT EXISTS dictionary_meta (
            id BIGINT PRIMARY KEY,
            version BIGINT NOT NULL DEFAULT 0,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    )
    # Seed the singleton row at version 0.
    op.execute(
        "INSERT INTO dictionary_meta (id, version) VALUES (1, 0) "
        "ON CONFLICT (id) DO NOTHING"
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS dictionary_removals")
    op.execute("DROP TABLE IF EXISTS dictionary_words")
    op.execute("DROP TABLE IF EXISTS dictionary_submissions")
    op.execute("DROP TABLE IF EXISTS dictionary_meta")
