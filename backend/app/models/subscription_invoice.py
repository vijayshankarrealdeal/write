"""Per-cycle invoice cache for reader subscriptions.

Razorpay issues one invoice per successful billing cycle. We pull
them on demand via `/v1/invoices?subscription_id=...` for the
Billing history page, but cache them locally so the page is fast and
survives a transient Razorpay outage. The webhook
(`subscription.charged` -> invoice attached) is the canonical writer;
the API route lazily backfills any gaps from Razorpay on the first
load after a subscribe so a delayed webhook doesn't leave a hole.

Idempotent on `razorpay_invoice_id` — a webhook replay or a backfill
that races the webhook is a no-op.
"""
import uuid
from datetime import datetime

from sqlalchemy import (
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


class SubscriptionInvoice(UUIDMixin, Base):
    __tablename__ = "subscription_invoices"

    subscription_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("subscriptions.id", ondelete="CASCADE"),
        nullable=False,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    razorpay_invoice_id: Mapped[str] = mapped_column(
        String(64), nullable=False, unique=True
    )
    # Populated once Razorpay captures the charge for this invoice.
    # Null on the issued-but-not-yet-paid window (rare — Razorpay
    # invoices on subscription are usually paid on issuance).
    razorpay_payment_id: Mapped[str | None] = mapped_column(String(64))
    # Razorpay invoice states: issued / paid / cancelled / expired.
    status: Mapped[str] = mapped_column(String(32), nullable=False)
    amount_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    currency: Mapped[str] = mapped_column(
        String(8), nullable=False, default="inr", server_default="inr"
    )
    # Bounds of the cycle this invoice covers — used to render
    # "April 22 – May 22" on the history rows.
    billing_period_start: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    billing_period_end: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    paid_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # Razorpay-hosted receipt URL (renders an invoice PDF). The Flutter
    # client opens this with url_launcher; we don't proxy the PDF.
    short_url: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    # Relationships
    subscription: Mapped["Subscription"] = relationship(back_populates="invoices")  # noqa: F821
    user: Mapped["User"] = relationship(foreign_keys=[user_id])  # noqa: F821

    __table_args__ = (
        # Billing history page renders "newest first, capped at 50"
        # per user; this index makes that a covering walk.
        Index(
            "ix_subscription_invoices_user_created",
            "user_id",
            "created_at",
            postgresql_using="btree",
        ),
    )
