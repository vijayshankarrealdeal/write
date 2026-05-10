"""Stripe Connect plumbing — single funnel for creator monetization.

Three external surfaces:

* `start_connect_onboarding(user, db)` — returns a hosted-onboarding URL
  the author opens in a browser. Creates an Express account on first
  call, then refreshes the onboarding link on every subsequent call so
  expired links don't strand the author mid-verification.
* `create_checkout_session(user, item)` — returns a hosted Checkout URL
  the reader opens to pay. Uses a destination charge with
  `application_fee_amount` so the platform's `stripe_platform_fee_bps`
  cut is withheld at charge time and the remainder lands in the
  author's connected balance instantly — no separate `transfer` call.
* `record_purchase_from_event(event, db)` — webhook handler. On
  `checkout.session.completed` with `payment_status == 'paid'`, writes
  the `purchases` row keyed on `payment_intent`. Idempotent: replays
  hit the unique constraint and no-op.

Authorization isn't checked here. Callers (the routers in
`app.routers.payments`) verify the requester owns the relevant entity
before invoking.
"""
from __future__ import annotations

import uuid

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.models.feed_item import FeedItem
from app.models.purchase import Purchase
from app.models.user import User


# Initialise the SDK lazily so a missing key (or a missing `stripe`
# package on a dev box that doesn't talk to Stripe at all) doesn't
# blow up the process at import time — the routers raise 503 in that
# case so the rest of the API keeps responding. This is also why we
# import the module inside the helper instead of at the top.
def _stripe():
    if not settings.stripe_secret_key:
        raise HTTPException(
            status_code=503, detail="Stripe is not configured on this deployment."
        )
    try:
        import stripe  # type: ignore[import-untyped]
    except ImportError as exc:  # pragma: no cover — prod always has it
        raise HTTPException(
            status_code=503,
            detail="Stripe SDK is not installed on the server.",
        ) from exc
    stripe.api_key = settings.stripe_secret_key
    return stripe


def _platform_fee_cents(amount_cents: int) -> int:
    """Platform fee in cents for [amount_cents], using
    `settings.stripe_platform_fee_bps` (basis points). 2000 bps = 20%.
    Rounds down — the author keeps the fractional cent on cheap items."""
    return (amount_cents * settings.stripe_platform_fee_bps) // 10_000


def _return_url(suffix: str = "") -> str:
    """Where Stripe sends the user after onboarding / Checkout. Falls
    back to `frontend_origin` so a single config rules both surfaces.
    Empty origin -> empty URL is rejected by Stripe later, surfacing as
    a 400 with a clear hint instead of a silent redirect to nowhere.
    """
    base = settings.stripe_return_url or settings.frontend_origin
    return f"{base.rstrip('/')}{suffix}"


async def start_connect_onboarding(user: User, db: AsyncSession) -> str:
    """Return a hosted-onboarding URL for [user]. Creates the Express
    account on the first call and persists `stripe_account_id` so the
    next call refreshes the link against the same account.

    Stripe AccountLink URLs expire (~minutes); we always mint a fresh
    one so an author who started onboarding yesterday and tapped the
    button again today doesn't hit a dead link.
    """
    s = _stripe()
    if not user.stripe_account_id:
        account = s.Account.create(
            type="express",
            email=user.email,
            capabilities={"transfers": {"requested": True}},
            metadata={"user_id": str(user.id)},
        )
        user.stripe_account_id = account.id
        await db.commit()
        await db.refresh(user)

    link = s.AccountLink.create(
        account=user.stripe_account_id,
        refresh_url=_return_url("?stripe_status=onboarding_refresh"),
        return_url=_return_url("?stripe_status=onboarding_return"),
        type="account_onboarding",
    )
    return link.url


async def refresh_account_status(user: User, db: AsyncSession) -> User:
    """Re-fetch the account from Stripe and persist `charges_enabled`.

    The webhook below also handles `account.updated` events, but the
    client polls this endpoint right after returning from onboarding so
    the publish dialog can flip from "Set up payouts" to "Ready to
    sell" without a webhook round-trip.
    """
    if not user.stripe_account_id:
        return user
    s = _stripe()
    account = s.Account.retrieve(user.stripe_account_id)
    new_state = bool(getattr(account, "charges_enabled", False))
    if user.stripe_charges_enabled != new_state:
        user.stripe_charges_enabled = new_state
        await db.commit()
        await db.refresh(user)
    return user


async def create_checkout_session(
    user: User, item: FeedItem, author: User
) -> str:
    """Return a hosted Checkout URL for `user` to buy `item`.

    Uses Stripe Connect destination charges: the platform creates the
    PaymentIntent, takes `application_fee_amount`, and routes the
    remainder onto the author's connected balance at charge time. No
    separate transfer / payout step — the author's balance increases
    the moment Stripe confirms the charge.

    Caller has already verified `item.price_cents > 0` and that the
    author has `stripe_charges_enabled`. Anything weaker would let a
    reader create Checkout sessions for free items or for authors who
    can't legally accept money yet.
    """
    s = _stripe()
    fee = _platform_fee_cents(item.price_cents)
    session = s.checkout.Session.create(
        mode="payment",
        line_items=[
            {
                "price_data": {
                    "currency": item.currency,
                    "product_data": {
                        "name": item.title or "Untitled",
                        "description": (item.description or "")[:500] or None,
                    },
                    "unit_amount": item.price_cents,
                },
                "quantity": 1,
            }
        ],
        payment_intent_data={
            "application_fee_amount": fee,
            "transfer_data": {"destination": author.stripe_account_id},
            "metadata": {
                "feed_item_id": str(item.id),
                "buyer_id": str(user.id),
                "author_id": str(author.id),
            },
        },
        # `metadata` on the Session itself so the webhook handler can
        # reach it without a separate PaymentIntent retrieve.
        metadata={
            "feed_item_id": str(item.id),
            "buyer_id": str(user.id),
            "author_id": str(author.id),
        },
        customer_email=user.email,
        success_url=_return_url(
            f"?stripe_status=purchase_success&feed_item_id={item.id}"
        ),
        cancel_url=_return_url(
            f"?stripe_status=purchase_cancel&feed_item_id={item.id}"
        ),
    )
    return session.url


def parse_webhook_event(payload: bytes, sig_header: str | None):
    """Verify the Stripe webhook signature and return the parsed event.

    Raises 400 on a missing/invalid signature so a tampered or replayed
    payload from outside Stripe doesn't reach `record_purchase_from_event`.
    """
    s = _stripe()
    if not settings.stripe_webhook_secret:
        raise HTTPException(
            status_code=503,
            detail="Stripe webhook secret is not configured.",
        )
    if not sig_header:
        raise HTTPException(status_code=400, detail="Missing Stripe signature.")
    try:
        return s.Webhook.construct_event(
            payload, sig_header, settings.stripe_webhook_secret
        )
    except Exception as e:  # stripe.error.SignatureVerificationError or ValueError
        raise HTTPException(status_code=400, detail=f"Invalid signature: {e}")


async def record_purchase_from_event(event, db: AsyncSession) -> None:
    """Persist a Purchase row when a Checkout session reports paid.

    Idempotent on `stripe_payment_intent_id`: a webhook replay hits the
    unique index and no-ops. The unique `(user_id, feed_item_id)` pair
    is the safety net against a buyer ever opening two Checkout sessions
    for the same book — the second insert raises and we discard it.
    """
    etype = event.get("type") or event["type"]
    if etype == "account.updated":
        await _apply_account_updated(event, db)
        return
    if etype != "checkout.session.completed":
        return
    session = event["data"]["object"]
    if session.get("payment_status") != "paid":
        return
    metadata = session.get("metadata") or {}
    feed_item_id_raw = metadata.get("feed_item_id")
    buyer_id_raw = metadata.get("buyer_id")
    author_id_raw = metadata.get("author_id")
    if not (feed_item_id_raw and buyer_id_raw and author_id_raw):
        # Not a checkout we created (e.g. a future product). Drop it.
        return

    payment_intent_id = session.get("payment_intent")
    if not payment_intent_id:
        return
    try:
        feed_item_id = uuid.UUID(feed_item_id_raw)
        buyer_id = uuid.UUID(buyer_id_raw)
        author_id = uuid.UUID(author_id_raw)
    except ValueError:
        return

    existing = await db.execute(
        select(Purchase).where(
            Purchase.stripe_payment_intent_id == payment_intent_id
        )
    )
    if existing.scalar_one_or_none() is not None:
        return

    amount_total = int(session.get("amount_total") or 0)
    currency = (session.get("currency") or "usd").lower()
    fee_cents = _platform_fee_cents(amount_total)
    purchase = Purchase(
        user_id=buyer_id,
        feed_item_id=feed_item_id,
        author_id=author_id,
        stripe_payment_intent_id=str(payment_intent_id),
        stripe_checkout_session_id=str(session.get("id") or "") or None,
        amount_cents=amount_total,
        platform_fee_cents=fee_cents,
        currency=currency,
    )
    db.add(purchase)
    try:
        await db.commit()
    except Exception:
        # Lost a race with the unique constraint — another worker
        # already recorded this purchase. Roll back and continue.
        await db.rollback()


async def _apply_account_updated(event, db: AsyncSession) -> None:
    """Mirror Stripe's `charges_enabled` onto the local user row so the
    publish dialog reflects onboarding completion without a manual
    refresh.
    """
    account = event["data"]["object"]
    account_id = account.get("id")
    if not account_id:
        return
    result = await db.execute(
        select(User).where(User.stripe_account_id == account_id)
    )
    user = result.scalar_one_or_none()
    if user is None:
        return
    new_state = bool(account.get("charges_enabled"))
    if user.stripe_charges_enabled != new_state:
        user.stripe_charges_enabled = new_state
        await db.commit()


__all__ = [
    "start_connect_onboarding",
    "refresh_account_status",
    "create_checkout_session",
    "parse_webhook_event",
    "record_purchase_from_event",
]
