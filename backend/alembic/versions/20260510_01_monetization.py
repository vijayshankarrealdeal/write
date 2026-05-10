"""Monetization: paid books + Stripe Connect.

Adds the schema for the creator-studio paid-publish flow:

* `feed_items.price_cents` / `currency` — per-card price. 0 means free
  (the historical default). Currency is an ISO-4217 code Stripe Checkout
  accepts; the column is intentionally lax so a future cross-currency
  rollout doesn't need a second migration.
* `sections.is_free_preview` — when the source feed item is paid, only
  preview-flagged sections are readable by non-purchasers. Ignored on
  free books (the price gate doesn't fire there).
* `users.stripe_account_id` / `stripe_charges_enabled` — author-side
  Connect account state. Both null/false until the author runs hosted
  Stripe onboarding from the publish dialog.
* `purchases` — reader -> feed_item ledger. One row per successful
  Checkout. The unique constraint on `stripe_payment_intent_id` is the
  webhook-replay safety net; the unique `(user_id, feed_item_id)` pair
  enforces "one purchase per book" so a duplicate Checkout is a no-op.

Revision ID: 20260510_01
Revises: 20260509_01
Create Date: 2026-05-10
"""
from __future__ import annotations

from alembic import op


revision = "20260510_01"
down_revision = "20260509_01"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE feed_items "
        "ADD COLUMN IF NOT EXISTS price_cents INTEGER NOT NULL DEFAULT 0"
    )
    op.execute(
        "ALTER TABLE feed_items "
        "ADD COLUMN IF NOT EXISTS currency VARCHAR(8) NOT NULL DEFAULT 'usd'"
    )
    op.execute(
        "ALTER TABLE sections "
        "ADD COLUMN IF NOT EXISTS is_free_preview BOOLEAN NOT NULL DEFAULT FALSE"
    )
    op.execute(
        "ALTER TABLE users "
        "ADD COLUMN IF NOT EXISTS stripe_account_id VARCHAR(64)"
    )
    op.execute(
        "ALTER TABLE users "
        "ADD COLUMN IF NOT EXISTS stripe_charges_enabled BOOLEAN NOT NULL DEFAULT FALSE"
    )
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS purchases (
            id UUID PRIMARY KEY,
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            feed_item_id UUID NOT NULL REFERENCES feed_items(id) ON DELETE CASCADE,
            author_id UUID NOT NULL REFERENCES users(id),
            stripe_payment_intent_id VARCHAR(128) NOT NULL UNIQUE,
            stripe_checkout_session_id VARCHAR(128),
            amount_cents INTEGER NOT NULL,
            platform_fee_cents INTEGER NOT NULL DEFAULT 0,
            currency VARCHAR(8) NOT NULL DEFAULT 'usd',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT uq_purchases_user_feed_item UNIQUE (user_id, feed_item_id)
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_purchases_user_feed_item "
        "ON purchases (user_id, feed_item_id)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_purchases_author_created "
        "ON purchases (author_id, created_at)"
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS purchases")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS stripe_charges_enabled")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS stripe_account_id")
    op.execute("ALTER TABLE sections DROP COLUMN IF EXISTS is_free_preview")
    op.execute("ALTER TABLE feed_items DROP COLUMN IF EXISTS currency")
    op.execute("ALTER TABLE feed_items DROP COLUMN IF EXISTS price_cents")
