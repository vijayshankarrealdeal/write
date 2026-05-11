"""Reader -> FeedItem purchase ledger.

One row per successful Razorpay payment for a paid feed item. Written
only by the Razorpay webhook handler after a `payment.captured` event
lands for an order we created, so the absence of a row means the user
has not paid (or the webhook hasn't landed yet — the client polls a
`/purchases/by-item` endpoint right after returning from the payment
link).

The `razorpay_payment_id` is unique so the webhook can replay without
double-recording on Razorpay's at-least-once delivery.
"""
import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, Integer, String, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UUIDMixin


class Purchase(UUIDMixin, Base):
    __tablename__ = "purchases"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    feed_item_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("feed_items.id", ondelete="CASCADE"), nullable=False
    )
    # Author at the moment of purchase. Snapshotted so a later author
    # account deletion or transfer doesn't break the receipt audit.
    author_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=False
    )
    razorpay_payment_id: Mapped[str] = mapped_column(
        String(128), nullable=False, unique=True
    )
    razorpay_order_id: Mapped[str | None] = mapped_column(String(128))
    amount_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    platform_fee_cents: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    currency: Mapped[str] = mapped_column(String(8), nullable=False, default="inr")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    user: Mapped["User"] = relationship(foreign_keys=[user_id])  # noqa: F821
    feed_item: Mapped["FeedItem"] = relationship()  # noqa: F821

    __table_args__ = (
        # One purchase per (reader, feed_item). A second payment for the
        # same book is a no-op — the unique constraint here is the safety
        # net for the webhook idempotency.
        UniqueConstraint("user_id", "feed_item_id", name="uq_purchases_user_feed_item"),
        # The reader-side gate query is "did this user buy this item?";
        # this index makes that a covering lookup.
        Index("ix_purchases_user_feed_item", "user_id", "feed_item_id"),
        # Author earnings dashboards walk by author_id.
        Index("ix_purchases_author_created", "author_id", "created_at"),
    )
