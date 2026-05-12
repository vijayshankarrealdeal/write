"""Reader-side Razorpay subscriptions (₹199/month).

The author-side schema landed in 20260510_01 (purchases) and was
renamed to Razorpay in 20260511_01. This migration adds the
reader-side recurring-billing schema:

* `users.razorpay_customer_id` — Razorpay Customer id minted on the
  first Subscribe tap and reused across every subsequent
  subscription.
* `users.active_subscription_id` — denormalised pointer to the
  current/most-recent `subscriptions` row so the per-request "is
  this user paying?" check is a single row read on `users`. NULLed
  when the subscription ends.
* `users.subscription_status` — mirrors the latest
  `subscriptions.status` for the same hot-path reason.
* `subscriptions` — one row per Razorpay subscription. State
  machine: created -> authenticated -> active ->
  (paused | halted | cancelled | completed). `amount_cents` is in
  paise (₹199 = 19900) matching the existing `purchases.amount_cents`
  semantics.
* `subscription_invoices` — local cache of Razorpay invoices, one
  per successful charge cycle. Unique on `razorpay_invoice_id` so
  webhook replays + lazy backfills don't double-write.

The FK `users.active_subscription_id -> subscriptions.id` is
declared *after* both tables exist because `subscriptions.user_id`
also references `users.id` — the cycle would otherwise prevent
either table from being created first.

Revision ID: 20260513_02
Revises: 20260513_01
Create Date: 2026-05-13
"""
from __future__ import annotations

from alembic import op


revision = "20260513_02"
down_revision = "20260513_01"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # --- users: three new nullable columns (no FK yet — added after
    # `subscriptions` exists to avoid the circular dependency).
    op.execute(
        "ALTER TABLE users "
        "ADD COLUMN IF NOT EXISTS razorpay_customer_id VARCHAR(64)"
    )
    op.execute(
        "ALTER TABLE users "
        "ADD COLUMN IF NOT EXISTS active_subscription_id UUID"
    )
    op.execute(
        "ALTER TABLE users "
        "ADD COLUMN IF NOT EXISTS subscription_status VARCHAR(32)"
    )

    # --- subscriptions
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS subscriptions (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            razorpay_subscription_id VARCHAR(64) NOT NULL UNIQUE,
            razorpay_customer_id VARCHAR(64) NOT NULL,
            razorpay_plan_id VARCHAR(64) NOT NULL,
            status VARCHAR(32) NOT NULL,
            short_url TEXT,
            current_start TIMESTAMPTZ,
            current_end TIMESTAMPTZ,
            charge_at TIMESTAMPTZ,
            cancel_at_cycle_end BOOLEAN NOT NULL DEFAULT FALSE,
            ended_at TIMESTAMPTZ,
            paid_count INTEGER NOT NULL DEFAULT 0,
            total_count INTEGER NOT NULL,
            amount_cents INTEGER NOT NULL,
            currency VARCHAR(8) NOT NULL DEFAULT 'inr',
            plan_label VARCHAR(64) NOT NULL DEFAULT '1 month',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_subscriptions_user_status "
        "ON subscriptions (user_id, status)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_subscriptions_status "
        "ON subscriptions (status)"
    )

    # --- subscription_invoices
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS subscription_invoices (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            subscription_id UUID NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            razorpay_invoice_id VARCHAR(64) NOT NULL UNIQUE,
            razorpay_payment_id VARCHAR(64),
            status VARCHAR(32) NOT NULL,
            amount_cents INTEGER NOT NULL,
            currency VARCHAR(8) NOT NULL DEFAULT 'inr',
            billing_period_start TIMESTAMPTZ,
            billing_period_end TIMESTAMPTZ,
            paid_at TIMESTAMPTZ,
            short_url TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_subscription_invoices_user_created "
        "ON subscription_invoices (user_id, created_at DESC)"
    )

    # --- deferred FK: users.active_subscription_id -> subscriptions.id.
    # Both tables now exist, so we can add the constraint. IF NOT EXISTS
    # for the constraint isn't supported in older Postgres versions, so
    # we use the DO block + pg_constraint lookup pattern for replay
    # safety.
    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_constraint WHERE conname = 'fk_users_active_subscription'
            ) THEN
                ALTER TABLE users
                ADD CONSTRAINT fk_users_active_subscription
                FOREIGN KEY (active_subscription_id)
                REFERENCES subscriptions(id);
            END IF;
        END
        $$
        """
    )


def downgrade() -> None:
    op.execute(
        "ALTER TABLE users DROP CONSTRAINT IF EXISTS fk_users_active_subscription"
    )
    op.execute("DROP TABLE IF EXISTS subscription_invoices")
    op.execute("DROP TABLE IF EXISTS subscriptions")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS subscription_status")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS active_subscription_id")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS razorpay_customer_id")
