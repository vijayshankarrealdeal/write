"""Payments API — author onboarding, reader checkout, Stripe webhook.

Surfaces the three entry points the Flutter client needs:

* `POST /api/payments/connect/onboard` — author opens hosted Stripe
  onboarding for their Express account.
* `GET  /api/payments/connect/status` — refresh + return whether the
  author can take charges yet.
* `POST /api/payments/checkout/{feed_item_id}` — reader gets a hosted
  Checkout URL for a paid book.
* `GET  /api/payments/purchases/by-item/{feed_item_id}` — short poll
  the client uses on return from Checkout to detect that the webhook
  has landed and the purchase row is live.
* `POST /api/payments/webhook` — Stripe webhook receiver. Anonymous;
  signature-verified.

Authorization is enforced here before delegating to `app.payments`.
"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.config import settings
from app.database import get_db
from app.models.feed_item import FeedItem
from app.models.purchase import Purchase
from app.models.user import User
from app.payments import (
    create_checkout_session,
    parse_webhook_event,
    record_purchase_from_event,
    refresh_account_status,
    start_connect_onboarding,
)


router = APIRouter(prefix="/api/payments", tags=["payments"])


class OnboardResponse(BaseModel):
    url: str
    account_id: str | None


class StatusResponse(BaseModel):
    account_id: str | None
    charges_enabled: bool
    platform_fee_bps: int


class CheckoutResponse(BaseModel):
    url: str


class PurchaseResponse(BaseModel):
    feed_item_id: UUID
    purchased: bool
    amount_cents: int | None = None
    currency: str | None = None


@router.post("/connect/onboard", response_model=OnboardResponse)
async def start_onboarding(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Mint a hosted onboarding URL for the calling author's Express
    account. Idempotent — second tap on a still-onboarding author
    returns a fresh link against the same account."""
    url = await start_connect_onboarding(user, db)
    return OnboardResponse(url=url, account_id=user.stripe_account_id)


@router.get("/connect/status", response_model=StatusResponse)
async def get_status(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Refresh the author's Connect status from Stripe and return it.
    The client polls this on return from onboarding so the publish
    dialog flips from "Set up payouts" to "Ready to sell" without
    waiting for the `account.updated` webhook."""
    if user.stripe_account_id:
        user = await refresh_account_status(user, db)
    return StatusResponse(
        account_id=user.stripe_account_id,
        charges_enabled=user.stripe_charges_enabled,
        platform_fee_bps=settings.stripe_platform_fee_bps,
    )


@router.post("/checkout/{feed_item_id}", response_model=CheckoutResponse)
async def start_checkout(
    feed_item_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Create a hosted Stripe Checkout session for [feed_item_id].

    Rejects:

    * non-existent / draft items (404 — same response as a hidden item
      so existence isn't leaked through the payments surface).
    * free items (400 — there's nothing to charge for).
    * the author trying to buy their own book (400).
    * an author who hasn't finished Connect onboarding (409 — the
      destination charge would otherwise fail at confirm time).
    * an item the user already owns (409 — surface the existing
      purchase so the client can navigate to the read view instead).
    """
    item = (
        await db.execute(
            select(FeedItem).where(
                FeedItem.id == feed_item_id, FeedItem.is_draft == False  # noqa: E712
            )
        )
    ).scalar_one_or_none()
    if item is None:
        raise HTTPException(status_code=404, detail="Feed item not found")
    if item.price_cents <= 0:
        raise HTTPException(status_code=400, detail="This item is free.")
    if item.author_id == user.id:
        raise HTTPException(status_code=400, detail="You can't buy your own book.")

    existing = (
        await db.execute(
            select(Purchase.id).where(
                Purchase.user_id == user.id,
                Purchase.feed_item_id == feed_item_id,
            )
        )
    ).scalar_one_or_none()
    if existing is not None:
        raise HTTPException(
            status_code=409, detail="You already own this book."
        )

    author = (
        await db.execute(select(User).where(User.id == item.author_id))
    ).scalar_one_or_none()
    if author is None or not author.stripe_account_id or not author.stripe_charges_enabled:
        raise HTTPException(
            status_code=409,
            detail="The author hasn't finished setting up payouts yet.",
        )

    url = await create_checkout_session(user, item, author)
    return CheckoutResponse(url=url)


@router.get(
    "/purchases/by-item/{feed_item_id}",
    response_model=PurchaseResponse,
)
async def get_purchase_for_item(
    feed_item_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Has the calling user purchased this feed item?

    Used by the post-Checkout return path: the client polls until
    `purchased` flips True (the Stripe webhook landed) so the reader
    transitions straight into the unlocked book without a hard refresh.
    """
    purchase = (
        await db.execute(
            select(Purchase).where(
                Purchase.user_id == user.id,
                Purchase.feed_item_id == feed_item_id,
            )
        )
    ).scalar_one_or_none()
    if purchase is None:
        return PurchaseResponse(feed_item_id=feed_item_id, purchased=False)
    return PurchaseResponse(
        feed_item_id=feed_item_id,
        purchased=True,
        amount_cents=purchase.amount_cents,
        currency=purchase.currency,
    )


@router.post("/webhook")
async def stripe_webhook(
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """Stripe webhook receiver. Anonymous — auth is the signature.

    Handles `checkout.session.completed` (writes the Purchase row) and
    `account.updated` (mirrors `charges_enabled` onto the author user).
    Returns `{"received": True}` on every signature-valid call so
    Stripe stops retrying.
    """
    payload = await request.body()
    sig = request.headers.get("stripe-signature")
    event = parse_webhook_event(payload, sig)
    await record_purchase_from_event(event, db)
    return {"received": True}
