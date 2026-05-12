"""Reader-side Razorpay monthly subscription ledger.

One row per Razorpay Subscription created on behalf of a user. The
hosted-payment-page short_url is stored at creation time and cleared
once the subscription transitions to `active` (the URL is no longer
useful at that point — Razorpay starts billing on the cycle schedule
and the user has no further authorization step to take).

The webhook handler is the only writer for status / cycle / paid_count
fields after the row is first inserted. Replays are made idempotent by
the unique `razorpay_subscription_id` — every subscription.* event
looks the row up by that key.

`amount_cents` is in paise (Razorpay's INR unit), matching the
`purchases.amount_cents` semantics: ₹199 = 19900 paise. `total_count`
is the number of billing cycles Razorpay will run before
`status=completed`; we use 120 (≈10 years) so the subscription is
effectively perpetual unless the user (or the platform) cancels.
"""
import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UUIDMixin


class Subscription(UUIDMixin, Base):
    __tablename__ = "subscriptions"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    razorpay_subscription_id: Mapped[str] = mapped_column(
        String(64), nullable=False, unique=True
    )
    razorpay_customer_id: Mapped[str] = mapped_column(String(64), nullable=False)
    razorpay_plan_id: Mapped[str] = mapped_column(String(64), nullable=False)
    # Razorpay state machine: created -> authenticated -> active ->
    # (paused | halted | cancelled | completed). `pending` is a
    # transient state Razorpay enters between a failed charge and the
    # next retry. Mirrors are kept eventually-consistent by the
    # /api/payments/webhook dispatcher.
    status: Mapped[str] = mapped_column(String(32), nullable=False)
    # Hosted Razorpay payment page where the user authorizes the
    # subscription mandate. Populated on creation; cleared once status
    # transitions to `active` since the URL is no longer actionable.
    short_url: Mapped[str | None] = mapped_column(Text)
    # Current billing cycle bounds, as reported by Razorpay. `current_end`
    # doubles as the "next charge date" surfaced in the UI.
    current_start: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    current_end: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    charge_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # True after the user (or platform) requests cancellation at the end
    # of the current cycle. Razorpay keeps the subscription `active`
    # until the cycle boundary, at which point it transitions to
    # `cancelled` and we set `ended_at`.
    cancel_at_cycle_end: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    paid_count: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    total_count: Mapped[int] = mapped_column(Integer, nullable=False)
    amount_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    currency: Mapped[str] = mapped_column(
        String(8), nullable=False, default="inr", server_default="inr"
    )
    plan_label: Mapped[str] = mapped_column(
        String(64), nullable=False, default="1 month", server_default="1 month"
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    # Relationships
    user: Mapped["User"] = relationship(back_populates="subscriptions", foreign_keys=[user_id])  # noqa: F821
    invoices: Mapped[list["SubscriptionInvoice"]] = relationship(  # noqa: F821
        back_populates="subscription", cascade="all, delete-orphan"
    )

    __table_args__ = (
        # "Does this user currently have an active subscription?" is the
        # hot-path admin / debug query; the denormalized
        # users.active_subscription_id covers the per-request gate, but
        # this index covers backfills and audits.
        Index("ix_subscriptions_user_status", "user_id", "status"),
        # Status-only sweeps run on the webhook side ("find all pending
        # rows older than X") and on dashboards.
        Index("ix_subscriptions_status", "status"),
    )
