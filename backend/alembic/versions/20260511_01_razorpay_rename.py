"""Rename Stripe columns to Razorpay (India market migration).

Stripe isn't available to merchants in India, so the monetization
funnel is being moved to Razorpay Route. The column shapes are
unchanged — we're only renaming so the model layer stops lying about
which processor is on the other end.

* `users.stripe_account_id` -> `razorpay_account_id`
* `users.stripe_charges_enabled` -> `razorpay_charges_enabled`
* `purchases.stripe_payment_intent_id` -> `razorpay_payment_id`
* `purchases.stripe_checkout_session_id` -> `razorpay_order_id`
* `purchases.currency` default 'usd' -> 'inr' (existing rows keep
  whatever they had — Razorpay only operates in INR for Indian
  merchants but historical rows are immutable receipts).

Revision ID: 20260511_01
Revises: 20260510_01
Create Date: 2026-05-11
"""
from __future__ import annotations

from alembic import op


revision = "20260511_01"
down_revision = "20260510_01"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE users "
        "RENAME COLUMN stripe_account_id TO razorpay_account_id"
    )
    op.execute(
        "ALTER TABLE users "
        "RENAME COLUMN stripe_charges_enabled TO razorpay_charges_enabled"
    )
    op.execute(
        "ALTER TABLE purchases "
        "RENAME COLUMN stripe_payment_intent_id TO razorpay_payment_id"
    )
    op.execute(
        "ALTER TABLE purchases "
        "RENAME COLUMN stripe_checkout_session_id TO razorpay_order_id"
    )
    # Default currency for new purchases on Indian Razorpay accounts.
    # Existing rows are unaffected — receipts stay in whatever currency
    # they were captured under.
    op.execute(
        "ALTER TABLE purchases ALTER COLUMN currency SET DEFAULT 'inr'"
    )


def downgrade() -> None:
    op.execute(
        "ALTER TABLE purchases ALTER COLUMN currency SET DEFAULT 'usd'"
    )
    op.execute(
        "ALTER TABLE purchases "
        "RENAME COLUMN razorpay_order_id TO stripe_checkout_session_id"
    )
    op.execute(
        "ALTER TABLE purchases "
        "RENAME COLUMN razorpay_payment_id TO stripe_payment_intent_id"
    )
    op.execute(
        "ALTER TABLE users "
        "RENAME COLUMN razorpay_charges_enabled TO stripe_charges_enabled"
    )
    op.execute(
        "ALTER TABLE users "
        "RENAME COLUMN razorpay_account_id TO stripe_account_id"
    )
