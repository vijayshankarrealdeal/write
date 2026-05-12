"""Reader subscriptions API — `₹199/month` Razorpay-billed plan.

Surfaces the five endpoints the Flutter client needs to drive
`SubscriptionPage` + `BillingHistoryPage`:

* `GET  /api/subscriptions/me` — caller's current state (status,
  next billing date, amount, payment method, manage/short URLs).
* `POST /api/subscriptions` — create a new Razorpay subscription;
  returns the hosted `short_url`. Idempotent against an in-flight one.
* `GET  /api/subscriptions/history` — newest-first invoice list.
  Lazily backfills from Razorpay when the local cache is empty so the
  first load after subscribing isn't blank if the webhook lagged.
* `POST /api/subscriptions/cancel` — at end of cycle (default) or
  immediate.
* `GET  /api/subscriptions/manage-payment-method` — hosted URL where
  the user can update their saved card / UPI.

Razorpay client wiring lives in `app.subscriptions` (A2). This module
only orchestrates: load/write rows, call those wrappers, shape responses.
"""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.config import settings
from app.database import get_db
from app.models.subscription import Subscription
from app.models.subscription_invoice import SubscriptionInvoice
from app.models.user import User
from app.subscriptions import (
    cancel_subscription,
    create_or_get_customer,
    create_subscription,
    list_invoices_for_subscription,
)


router = APIRouter(prefix="/api/subscriptions", tags=["subscriptions"])


# ---------------- response models -----------------

class SubscriptionMeResponse(BaseModel):
    status: str
    plan_label: str | None = None
    amount_cents: int | None = None
    currency: str | None = None
    current_period_end: datetime | None = None
    cancel_at_cycle_end: bool = False
    payment_method: str | None = None
    short_url: str | None = None
    manage_url: str | None = None


class StartSubscriptionResponse(BaseModel):
    subscription_id: str
    short_url: str


class BillingInvoiceItem(BaseModel):
    id: UUID
    amount_cents: int
    currency: str
    status: str
    billing_period_start: datetime | None = None
    billing_period_end: datetime | None = None
    paid_at: datetime | None = None
    receipt_url: str | None = None


class BillingHistoryResponse(BaseModel):
    items: list[BillingInvoiceItem]


class CancelRequest(BaseModel):
    immediate: bool = False


class CancelResponse(BaseModel):
    status: str
    cancel_at_cycle_end: bool
    ends_at: datetime | None = None


class ManagePaymentResponse(BaseModel):
    url: str


# ---------------- helpers -----------------

# In-flight states — a subscription in any of these still owns the
# user's "current subscription" slot. New POSTs return the existing
# row instead of double-charging.
_LIVE_STATES = frozenset({
    "created", "authenticated", "active", "pending", "halted",
})

_PLAN_AMOUNT_CENTS = 19900  # ₹199; matches the Razorpay Plan body.
_TOTAL_COUNT = 120          # ~10 years of monthly cycles; effectively perpetual.
_PLAN_LABEL = "1 month"


def _require_plan_id() -> str:
    """Return the configured plan id or 503 if unset.

    Empty `razorpay_plan_id_monthly` means the operator hasn't run
    `scripts/create_razorpay_plan.py` yet — failing loudly here is
    better than silently creating a subscription against an empty
    plan id.
    """
    plan_id = settings.razorpay_plan_id_monthly
    if not plan_id:
        raise HTTPException(
            status_code=503,
            detail="Subscriptions are not configured on this deployment.",
        )
    return plan_id


async def _load_active_subscription(
    user: User, db: AsyncSession
) -> Subscription | None:
    """Return the user's active subscription row, if any.

    Uses the denormalized pointer on `users.active_subscription_id` so
    this is a single keyed lookup, no scan.
    """
    if user.active_subscription_id is None:
        return None
    row = await db.execute(
        select(Subscription).where(Subscription.id == user.active_subscription_id)
    )
    return row.scalar_one_or_none()


async def _find_inflight_subscription(
    user: User, db: AsyncSession
) -> Subscription | None:
    """Find any not-yet-terminated subscription for [user].

    Falls back to a scan of the user's subscriptions when the
    `active_subscription_id` pointer is null (post-cancel state) so
    a user who cancelled mid-cycle and immediately retried can't
    accidentally end up with two parallel subscriptions billing them.
    """
    if user.active_subscription_id is not None:
        existing = await _load_active_subscription(user, db)
        if existing is not None and existing.status in _LIVE_STATES:
            return existing
    rows = await db.execute(
        select(Subscription)
        .where(Subscription.user_id == user.id)
        .where(Subscription.status.in_(_LIVE_STATES))
        .order_by(Subscription.created_at.desc())
    )
    return rows.scalars().first()


def _ts_to_dt(ts: int | None) -> datetime | None:
    """Razorpay returns timestamps as unix-second ints. Promote to
    timezone-aware UTC datetimes; pass `None` through untouched."""
    if ts is None:
        return None
    return datetime.fromtimestamp(int(ts), tz=timezone.utc)


# ---------------- endpoints -----------------

@router.get("/me", response_model=SubscriptionMeResponse)
async def get_me(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Return the caller's subscription state.

    `status="none"` means the user has never subscribed (or has fully
    ended their subscription) — the client renders a Subscribe CTA.
    Otherwise the full row is mapped: `current_period_end` is the
    `current_end` column, `short_url` is populated only while the user
    still needs to authorize, and `manage_url` is the hosted re-auth
    URL we surface when Razorpay has halted billing after retries.
    """
    sub = await _load_active_subscription(user, db)
    if sub is None:
        return SubscriptionMeResponse(status="none")

    # `short_url` is meaningful only before activation — once Razorpay
    # has captured the first charge we clear it (the webhook does this
    # on `subscription.activated`). `manage_url` is the same hosted URL
    # but surfaced for a different reason: re-authorize after a halt.
    short_url = sub.short_url if sub.status in {"created", "authenticated"} else None
    manage_url = sub.short_url if sub.status == "halted" else None

    return SubscriptionMeResponse(
        status=sub.status,
        plan_label=sub.plan_label,
        amount_cents=sub.amount_cents,
        currency=sub.currency,
        current_period_end=sub.current_end,
        cancel_at_cycle_end=sub.cancel_at_cycle_end,
        payment_method="Razorpay",
        short_url=short_url,
        manage_url=manage_url,
    )


@router.post("", response_model=StartSubscriptionResponse)
async def start_subscription(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Create a new Razorpay subscription and return its hosted URL.

    Idempotent: if the user already has a live row (created /
    authenticated / active / pending / halted), the existing row's
    `short_url` is returned instead of minting a second subscription.

    First-time path:
      1. Ensure the user has a Razorpay Customer (lazy-create + persist).
      2. Create the Razorpay Subscription against the monthly plan.
      3. Mirror the response into a `subscriptions` row.
      4. Point `users.active_subscription_id` at the new row.
    """
    plan_id = _require_plan_id()

    existing = await _find_inflight_subscription(user, db)
    if existing is not None:
        return StartSubscriptionResponse(
            subscription_id=existing.razorpay_subscription_id,
            short_url=existing.short_url or "",
        )

    # Customer: lazy-create on first subscribe so readers who never opt
    # in never get a Razorpay record. A2's wrapper handles the
    # "already exists" case and returns the cached id.
    customer_id = create_or_get_customer(user)
    if user.razorpay_customer_id != customer_id:
        user.razorpay_customer_id = customer_id
        await db.commit()
        await db.refresh(user)

    response = create_subscription(
        plan_id=plan_id,
        customer_id=customer_id,
        total_count=_TOTAL_COUNT,
        user_id=str(user.id),
    )

    sub = Subscription(
        user_id=user.id,
        razorpay_subscription_id=response["id"],
        razorpay_customer_id=customer_id,
        razorpay_plan_id=plan_id,
        status=(response.get("status") or "created").lower(),
        short_url=response.get("short_url"),
        current_start=_ts_to_dt(response.get("current_start")),
        current_end=_ts_to_dt(response.get("current_end")),
        charge_at=_ts_to_dt(response.get("charge_at")),
        cancel_at_cycle_end=False,
        paid_count=int(response.get("paid_count") or 0),
        total_count=int(response.get("total_count") or _TOTAL_COUNT),
        amount_cents=_PLAN_AMOUNT_CENTS,
        currency="inr",
        plan_label=_PLAN_LABEL,
    )
    db.add(sub)
    await db.flush()  # populate sub.id before we point the user row at it

    user.active_subscription_id = sub.id
    user.subscription_status = sub.status
    await db.commit()
    await db.refresh(sub)

    return StartSubscriptionResponse(
        subscription_id=sub.razorpay_subscription_id,
        short_url=sub.short_url or "",
    )


@router.get("/history", response_model=BillingHistoryResponse)
async def get_history(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Return the caller's invoices, newest first, capped at 50.

    Hot path is a local-cache read (the webhook populates rows on
    `subscription.charged` / `invoice.paid`). When the cache is empty
    but the user does have an active subscription, we lazily backfill
    from Razorpay's `/v1/invoices?subscription_id=...` so the first
    load after subscribing isn't blank when the webhook is slow.
    """
    rows = await db.execute(
        select(SubscriptionInvoice)
        .where(SubscriptionInvoice.user_id == user.id)
        .order_by(SubscriptionInvoice.created_at.desc())
        .limit(50)
    )
    invoices = list(rows.scalars().all())

    if not invoices:
        sub = await _load_active_subscription(user, db)
        if sub is not None:
            try:
                remote = list_invoices_for_subscription(
                    sub.razorpay_subscription_id
                )
            except Exception:
                # Razorpay temporarily unreachable; serve the empty
                # cache instead of 500-ing — the webhook will catch up.
                remote = []
            for entity in remote or []:
                await _upsert_invoice_from_entity(entity, sub, user, db)
            if remote:
                await db.commit()
                rows = await db.execute(
                    select(SubscriptionInvoice)
                    .where(SubscriptionInvoice.user_id == user.id)
                    .order_by(SubscriptionInvoice.created_at.desc())
                    .limit(50)
                )
                invoices = list(rows.scalars().all())

    items = [
        BillingInvoiceItem(
            id=inv.id,
            amount_cents=inv.amount_cents,
            currency=inv.currency,
            status=inv.status,
            billing_period_start=inv.billing_period_start,
            billing_period_end=inv.billing_period_end,
            paid_at=inv.paid_at,
            receipt_url=inv.short_url,
        )
        for inv in invoices
    ]
    return BillingHistoryResponse(items=items)


async def _upsert_invoice_from_entity(
    entity: dict,
    sub: Subscription,
    user: User,
    db: AsyncSession,
) -> None:
    """Idempotently insert a `subscription_invoices` row from a
    Razorpay invoice entity dict.

    Skips when `razorpay_invoice_id` is already on file. Used by both
    the lazy backfill above and the webhook dispatcher in
    `app.payments._apply_subscription_event` — same shape, same rules.
    """
    invoice_id = entity.get("id")
    if not invoice_id:
        return
    existing = await db.execute(
        select(SubscriptionInvoice.id).where(
            SubscriptionInvoice.razorpay_invoice_id == invoice_id
        )
    )
    if existing.scalar_one_or_none() is not None:
        return

    paid_at_ts = entity.get("paid_at") or entity.get("paid_at_ts")
    period_start = entity.get("billing_start") or entity.get("period_start")
    period_end = entity.get("billing_end") or entity.get("period_end")
    payment_id = entity.get("payment_id")
    invoice = SubscriptionInvoice(
        subscription_id=sub.id,
        user_id=user.id,
        razorpay_invoice_id=str(invoice_id),
        razorpay_payment_id=str(payment_id) if payment_id else None,
        status=(entity.get("status") or "issued").lower(),
        amount_cents=int(entity.get("amount") or 0),
        currency=(entity.get("currency") or "inr").lower(),
        billing_period_start=_ts_to_dt(period_start),
        billing_period_end=_ts_to_dt(period_end),
        paid_at=_ts_to_dt(paid_at_ts),
        short_url=entity.get("short_url"),
    )
    db.add(invoice)


@router.post("/cancel", response_model=CancelResponse)
async def cancel(
    body: CancelRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Cancel the caller's active subscription.

    Default (`immediate=False`) schedules cancellation at the end of
    the current billing cycle — Razorpay keeps charging access live
    until `current_end`. `immediate=True` ends it now and clears the
    user's active pointer so the UI flips straight back to the
    Subscribe CTA.
    """
    sub = await _load_active_subscription(user, db)
    if sub is None:
        raise HTTPException(status_code=404, detail="No active subscription.")

    cancel_subscription(
        sub.razorpay_subscription_id, immediate=body.immediate
    )

    sub.cancel_at_cycle_end = not body.immediate
    if body.immediate:
        sub.status = "cancelled"
        now = datetime.now(tz=timezone.utc)
        sub.ended_at = now
        user.active_subscription_id = None
        user.subscription_status = "cancelled"
        ends_at: datetime | None = now
    else:
        # Cycle-end cancel — Razorpay continues to bill nothing further
        # but the subscription remains "active" until current_end.
        ends_at = sub.current_end

    await db.commit()
    await db.refresh(sub)

    return CancelResponse(
        status=sub.status,
        cancel_at_cycle_end=sub.cancel_at_cycle_end,
        ends_at=ends_at,
    )


@router.get("/manage-payment-method", response_model=ManagePaymentResponse)
async def manage_payment_method(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Return a hosted Razorpay URL the user can open to update their
    saved card / UPI. We surface the subscription's `short_url` —
    Razorpay re-uses it as the re-authorize page when status=halted.
    """
    sub = await _load_active_subscription(user, db)
    if sub is None or not sub.short_url:
        raise HTTPException(status_code=404, detail="No active subscription.")
    return ManagePaymentResponse(url=sub.short_url)
