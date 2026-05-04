"""Admin audit log + retention-friendly dictionary submissions.

Revision ID: 20260504_02
Revises: 20260504_01
Create Date: 2026-05-04

Adds:
- ``admin_audit`` table: append-only log of privileged admin actions
  (dictionary merges, global word removals, etc.). Surfaced via
  ``GET /api/admin/audit``.
- Loosens ``dictionary_submissions.user_id`` from NOT NULL → NULL with
  ``ON DELETE SET NULL`` so the daily retention sweep can anonymise
  rows older than ``DICTIONARY_SUBMISSION_RETENTION_DAYS`` (default
  365) per the privacy policy.

Idempotent (``IF NOT EXISTS`` / ``IF EXISTS``) so dev DBs that came up
through ``Base.metadata.create_all`` aren't double-bumped.
"""
from __future__ import annotations

from alembic import op


revision = "20260504_02"
down_revision = "20260504_01"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Admin audit log.
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS admin_audit (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            admin_username VARCHAR(80) NOT NULL,
            action VARCHAR(64) NOT NULL,
            target JSONB,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_admin_audit_action "
        "ON admin_audit (action)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_admin_audit_created_at "
        "ON admin_audit (created_at)"
    )

    # Retention sweep flips user_id → NULL on rows past the window.
    # That requires the column to be nullable and the FK to be SET NULL
    # rather than CASCADE so an old row that loses its user doesn't
    # also lose itself — the audit value is the *word*, not the user.
    op.execute(
        "ALTER TABLE dictionary_submissions "
        "ALTER COLUMN user_id DROP NOT NULL"
    )
    # Drop the existing FK and recreate with ON DELETE SET NULL.
    # ``IF EXISTS`` covers dev DBs whose constraint name differs.
    op.execute(
        """
        DO $$
        DECLARE
            con_name TEXT;
        BEGIN
            SELECT conname INTO con_name
            FROM pg_constraint
            WHERE conrelid = 'dictionary_submissions'::regclass
              AND contype = 'f'
              AND pg_get_constraintdef(oid) LIKE '%REFERENCES users%';
            IF con_name IS NOT NULL THEN
                EXECUTE format(
                    'ALTER TABLE dictionary_submissions DROP CONSTRAINT %I',
                    con_name
                );
            END IF;
        END $$;
        """
    )
    op.execute(
        "ALTER TABLE dictionary_submissions "
        "ADD CONSTRAINT dictionary_submissions_user_id_fkey "
        "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL"
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS admin_audit")
    # Best-effort: if there are NULL rows from a retention sweep we
    # can't safely set them back to NOT NULL, so leave the column as
    # nullable on downgrade. Restore the FK to CASCADE.
    op.execute(
        """
        DO $$
        DECLARE
            con_name TEXT;
        BEGIN
            SELECT conname INTO con_name
            FROM pg_constraint
            WHERE conrelid = 'dictionary_submissions'::regclass
              AND contype = 'f'
              AND pg_get_constraintdef(oid) LIKE '%REFERENCES users%';
            IF con_name IS NOT NULL THEN
                EXECUTE format(
                    'ALTER TABLE dictionary_submissions DROP CONSTRAINT %I',
                    con_name
                );
            END IF;
        END $$;
        """
    )
    op.execute(
        "ALTER TABLE dictionary_submissions "
        "ADD CONSTRAINT dictionary_submissions_user_id_fkey "
        "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE"
    )
