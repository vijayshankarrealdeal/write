"""User country_code (ISO 3166-1 alpha-2).

Adds a nullable two-letter country code to `users`. Populated from the
request IP on the first authenticated call after the column lands —
`app.geo.resolve_country_code` does the work, called via a background
task in `app.auth.deps.get_current_user` so auth latency isn't held
by the lookup.

Powers two things:

* Payment-provider routing — once a second processor (Stripe, PayPal)
  is wired up, `POST /api/subscriptions` branches on `country_code` to
  pick Razorpay (`IN`) vs the international one. Today every user goes
  through Razorpay regardless, so the column is observational until
  that fork lands.
* Admin dashboard country breakdown — `/api/admin/analytics/user-
  activity` includes a country histogram alongside the existing
  platform mix.

Revision ID: 20260514_01
Revises: 20260513_02
Create Date: 2026-05-14
"""
from __future__ import annotations

from alembic import op


revision = "20260514_01"
down_revision = "20260513_02"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE users "
        "ADD COLUMN IF NOT EXISTS country_code VARCHAR(2)"
    )
    # Partial index — the admin dashboard's country breakdown groups by
    # country_code where it's not null, which is a small subset of users
    # at first. Partial keeps the index tiny and the GROUP BY fast.
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_users_country_code "
        "ON users (country_code) WHERE country_code IS NOT NULL"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_users_country_code")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS country_code")
