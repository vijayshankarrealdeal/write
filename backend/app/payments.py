"""Razorpay Route plumbing — single funnel for creator monetization.

Three external surfaces:

* `start_connect_onboarding(user, db)` — returns a hosted-onboarding
  URL the author opens in a browser. Creates a Razorpay Linked Account
  on first call and requests the Route product to mint an activation
  form link, then refreshes the link on every subsequent call so
  expired/stale links don't strand the author mid-KYC.
* `create_checkout_session(user, item)` — returns a hosted Payment
  Link URL the reader opens to pay. Creates an Order keyed on the
  feed item + buyer (metadata in `notes`) and a Payment Link tied to
  that order. Route transfers are fanned out on the `payment.captured`
  webhook so the platform's `razorpay_platform_fee_bps` cut is retained
  and the remainder lands in the author's linked-account balance.
* `record_purchase_from_event(event, db)` — webhook handler. On
  `payment.captured` with a matching order in our `notes` map, writes
  the `purchases` row keyed on `razorpay_payment_id` and creates a
  Route transfer of `amount - platform_fee` to the author. Idempotent:
  replays hit the unique constraint and no-op; transfer creation also
  catches "already transferred" errors.

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


# Initialise the SDK lazily so a missing key (or a missing `razorpay`
# package on a dev box that doesn't talk to Razorpay at all) doesn't
# blow up the process at import time — the routers raise 503 in that
# case so the rest of the API keeps responding. This is also why we
# import the module inside the helper instead of at the top.
def _razorpay():
    if not settings.razorpay_key_id or not settings.razorpay_key_secret:
        raise HTTPException(
            status_code=503, detail="Razorpay is not configured on this deployment."
        )
    try:
        import razorpay  # type: ignore[import-untyped]
    except ImportError as exc:  # pragma: no cover — prod always has it
        raise HTTPException(
            status_code=503,
            detail="Razorpay SDK is not installed on the server.",
        ) from exc
    return razorpay.Client(
        auth=(settings.razorpay_key_id, settings.razorpay_key_secret)
    )


def _platform_fee_cents(amount_cents: int) -> int:
    """Platform fee in paise for [amount_cents], using
    `settings.razorpay_platform_fee_bps` (basis points). 2000 bps = 20%.
    Rounds down — the author keeps the fractional paisa on cheap items."""
    return (amount_cents * settings.razorpay_platform_fee_bps) // 10_000


def _return_url(suffix: str = "") -> str:
    """Where Razorpay sends the user after onboarding / Payment Link.
    Falls back to `frontend_origin` so a single config rules both
    surfaces. Empty origin -> empty URL is rejected by Razorpay later,
    surfacing as a 400 with a clear hint instead of a silent redirect
    to nowhere.
    """
    base = settings.razorpay_return_url or settings.frontend_origin
    return f"{base.rstrip('/')}{suffix}"


async def start_connect_onboarding(user: User, db: AsyncSession) -> str:
    """Return a hosted-onboarding URL for [user]. Creates the Razorpay
    Linked Account on the first call, requests the Route product, and
    persists `razorpay_account_id` so the next call refreshes the
    activation link against the same account.

    Razorpay activation form links don't expire as aggressively as
    some processors' onboarding URLs, but we still mint a fresh one
    each call so an author returning to finish KYC doesn't hit a stale
    page.
    """
    rzp = _razorpay()
    try:
        if not user.razorpay_account_id:
            # Razorpay v2 Linked Account creation. `type=route` declares
            # the marketplace intent; `reference_id` lets us correlate
            # webhook events back to our local user without an extra
            # lookup.
            account = rzp.account.create({
                "email": user.email,
                "type": "route",
                "reference_id": str(user.id),
                "legal_business_name": user.name or "Individual",
                "business_type": "individual",
                "contact_name": user.name or "Author",
                "profile": {
                    "category": "education",
                    "subcategory": "other",
                },
            })
            user.razorpay_account_id = account["id"]
            await db.commit()
            await db.refresh(user)

        # Request Route product configuration; the response carries the
        # `activation_form_link` Razorpay hosts for KYC + bank-detail
        # capture. Idempotent — Razorpay returns the same link for a
        # still-onboarding account.
        product = rzp.product.request_product_configuration(
            user.razorpay_account_id,
            {
                "product_name": "route",
                "tnc_accepted": True,
            },
        )
    except Exception as exc:
        # Surface Razorpay's own message as a 409 instead of a generic
        # 500. Common cases we hit here:
        #   * "Route feature not enabled for the merchant" — the
        #     platform hasn't been approved for Route yet; the author
        #     can't be onboarded until Razorpay grants access.
        #   * Field validation errors on the v2 account payload.
        # 409 lets the Flutter client show the verbatim reason in the
        # publish dialog without leaking a stack trace.
        raise HTTPException(status_code=409, detail=str(exc))

    link = (
        product.get("activation_form_link")
        or product.get("activation_url")
        or _return_url("?razorpay_status=onboarding_pending")
    )
    return link


async def refresh_account_status(user: User, db: AsyncSession) -> User:
    """Re-fetch the linked account from Razorpay and persist
    `razorpay_charges_enabled`.

    The webhook below also handles `account.updated` events, but the
    client polls this endpoint right after returning from onboarding so
    the publish dialog can flip from "Set up payouts" to "Ready to
    sell" without a webhook round-trip.
    """
    if not user.razorpay_account_id:
        return user
    rzp = _razorpay()
    try:
        account = rzp.account.fetch(user.razorpay_account_id)
    except Exception:
        # If Razorpay is unreachable or the account has been wiped on
        # their side, fall back to the locally-cached state rather than
        # 500-ing the polling endpoint. The webhook handler is the
        # authoritative refresh path anyway.
        return user
    # Razorpay marks a linked account ready to receive transfers when
    # its `status` is `activated`. Activation requires KYC + bank
    # details + Route product configuration to be complete.
    status = (account.get("status") or "").lower()
    new_state = status == "activated"
    if user.razorpay_charges_enabled != new_state:
        user.razorpay_charges_enabled = new_state
        await db.commit()
        await db.refresh(user)
    return user


async def create_checkout_session(
    user: User, item: FeedItem, author: User
) -> str:
    """Return a hosted Payment Link URL for `user` to buy `item`.

    Uses Razorpay Orders + Payment Links: the platform creates the
    Order with metadata in `notes` so the webhook can correlate the
    `payment.captured` event back to our buyer + book, then mints a
    Payment Link tied to that order. The Route transfer (amount minus
    platform fee) is fanned out on capture rather than at order
    creation, which keeps the author's payout idempotent against the
    webhook and avoids holding funds if the buyer abandons checkout.

    Caller has already verified `item.price_cents > 0` and that the
    author has `razorpay_charges_enabled`. Anything weaker would let a
    reader create payment sessions for free items or for authors who
    can't legally accept money yet.
    """
    rzp = _razorpay()
    notes = {
        "feed_item_id": str(item.id),
        "buyer_id": str(user.id),
        "author_id": str(author.id),
    }
    try:
        order = rzp.order.create({
            "amount": item.price_cents,
            "currency": item.currency.upper(),
            "notes": notes,
        })
        link = rzp.payment_link.create({
            "amount": item.price_cents,
            "currency": item.currency.upper(),
            "accept_partial": False,
            "description": (item.title or "Untitled")[:255],
            "customer": {
                "email": user.email,
                "name": user.name or "",
            },
            "notify": {"sms": False, "email": False},
            "reminder_enable": False,
            "notes": {**notes, "order_id": order["id"]},
            "callback_url": _return_url(
                f"?razorpay_status=purchase_success&feed_item_id={item.id}"
            ),
            "callback_method": "get",
        })
    except Exception as exc:
        # Same pattern as onboarding — surface Razorpay's reason as a
        # 409 so the buyer sees a clean message ("payment temporarily
        # unavailable") instead of a 500 stack trace.
        raise HTTPException(status_code=409, detail=str(exc))
    return link["short_url"]


def parse_webhook_event(payload: bytes, sig_header: str | None):
    """Verify the Razorpay webhook signature and return the parsed event.

    Raises 400 on a missing/invalid signature so a tampered or replayed
    payload from outside Razorpay doesn't reach `record_purchase_from_event`.
    """
    import json

    rzp = _razorpay()
    if not settings.razorpay_webhook_secret:
        raise HTTPException(
            status_code=503,
            detail="Razorpay webhook secret is not configured.",
        )
    if not sig_header:
        raise HTTPException(status_code=400, detail="Missing Razorpay signature.")
    try:
        rzp.utility.verify_webhook_signature(
            payload.decode("utf-8"),
            sig_header,
            settings.razorpay_webhook_secret,
        )
    except Exception as e:  # razorpay.errors.SignatureVerificationError or ValueError
        raise HTTPException(status_code=400, detail=f"Invalid signature: {e}")
    try:
        return json.loads(payload.decode("utf-8"))
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid payload: {e}")


async def record_purchase_from_event(event, db: AsyncSession) -> None:
    """Persist a Purchase row when a payment is captured and fan out
    the Route transfer to the author.

    Idempotent on `razorpay_payment_id`: a webhook replay hits the
    unique index and no-ops. The unique `(user_id, feed_item_id)` pair
    is the safety net against a buyer ever opening two Payment Links
    for the same book — the second insert raises and we discard it.
    """
    etype = event.get("event") or event.get("type") or ""
    if etype.startswith("account."):
        await _apply_account_updated(event, etype, db)
        return
    if etype != "payment.captured":
        return
    payload = event.get("payload") or {}
    payment_envelope = payload.get("payment") or {}
    payment = payment_envelope.get("entity") or {}
    if not payment:
        return
    if (payment.get("status") or "").lower() != "captured":
        return
    notes = payment.get("notes") or {}
    feed_item_id_raw = notes.get("feed_item_id")
    buyer_id_raw = notes.get("buyer_id")
    author_id_raw = notes.get("author_id")
    if not (feed_item_id_raw and buyer_id_raw and author_id_raw):
        # Not a payment we created (e.g. a future product, or a Payment
        # Link minted outside this funnel). Drop it.
        return

    payment_id = payment.get("id")
    if not payment_id:
        return
    try:
        feed_item_id = uuid.UUID(feed_item_id_raw)
        buyer_id = uuid.UUID(buyer_id_raw)
        author_id = uuid.UUID(author_id_raw)
    except ValueError:
        return

    existing = await db.execute(
        select(Purchase).where(
            Purchase.razorpay_payment_id == payment_id
        )
    )
    if existing.scalar_one_or_none() is not None:
        return

    amount_total = int(payment.get("amount") or 0)
    currency = (payment.get("currency") or "inr").lower()
    fee_cents = _platform_fee_cents(amount_total)
    order_id = payment.get("order_id") or notes.get("order_id")
    purchase = Purchase(
        user_id=buyer_id,
        feed_item_id=feed_item_id,
        author_id=author_id,
        razorpay_payment_id=str(payment_id),
        razorpay_order_id=str(order_id) if order_id else None,
        amount_cents=amount_total,
        platform_fee_cents=fee_cents,
        currency=currency,
    )
    db.add(purchase)
    try:
        await db.commit()
    except Exception:
        # Lost a race with the unique constraint — another worker
        # already recorded this purchase. Roll back and continue; the
        # transfer below is also idempotent so the duplicate-webhook
        # path is safe.
        await db.rollback()
        return

    # Fan out the Route transfer to the author's linked account. The
    # platform keeps `fee_cents`; the author receives the remainder.
    # Razorpay rejects a second transfer-from-payment for the same
    # payment_id, so this is naturally idempotent against webhook
    # replays.
    author_q = await db.execute(select(User).where(User.id == author_id))
    author = author_q.scalar_one_or_none()
    if author is None or not author.razorpay_account_id:
        return
    net_cents = max(0, amount_total - fee_cents)
    if net_cents <= 0:
        return
    try:
        rzp = _razorpay()
        rzp.payment.transfer(
            payment_id,
            {
                "transfers": [
                    {
                        "account": author.razorpay_account_id,
                        "amount": net_cents,
                        "currency": currency.upper(),
                        "notes": {
                            "feed_item_id": str(feed_item_id),
                            "author_id": str(author_id),
                        },
                        "on_hold": 0,
                    }
                ]
            },
        )
    except Exception:
        # Already-transferred / linked account not yet activated /
        # transient network error. The transfer can be reconciled
        # out-of-band; we don't fail the webhook (Razorpay would
        # otherwise keep retrying and the purchase row is already saved).
        pass


_ACTIVATING_ACCOUNT_EVENTS = frozenset({
    # Razorpay activates a linked account in one of two paths:
    #   * `instantly_activated` — small merchants get instant access
    #     for payment capture without waiting for full KYC review.
    #   * `activated_kyc_pending` — provisional activation; the account
    #     can take payments / transfers while KYC review continues.
    # Both signal "ready to receive Route transfers" for our purposes.
    "account.instantly_activated",
    "account.activated_kyc_pending",
})

_DEACTIVATING_ACCOUNT_EVENTS = frozenset({
    # Anything that takes the account back out of the activated set.
    # `needs_clarification` and `under_review` block transfers; `suspended`
    # and `rejected` are terminal failures. Mirror them onto the local
    # `charges_enabled` flag so the publish dialog stops offering paid
    # pricing the moment Razorpay flips state.
    "account.under_review",
    "account.needs_clarification",
    "account.suspended",
    "account.rejected",
})


async def _apply_account_updated(event, etype: str, db: AsyncSession) -> None:
    """Mirror Razorpay's linked-account state onto the local user row so
    the publish dialog reflects onboarding completion without a manual
    refresh.

    Razorpay emits distinct event names per state transition rather
    than a single generic update event, so we infer activation from
    the event name itself instead of parsing a `status` field that
    isn't always populated on the entity body.
    """
    payload = event.get("payload") or {}
    account_envelope = payload.get("account") or {}
    account = account_envelope.get("entity") or {}
    account_id = account.get("id")
    if not account_id:
        return
    result = await db.execute(
        select(User).where(User.razorpay_account_id == account_id)
    )
    user = result.scalar_one_or_none()
    if user is None:
        return
    if etype in _ACTIVATING_ACCOUNT_EVENTS:
        new_state = True
    elif etype in _DEACTIVATING_ACCOUNT_EVENTS:
        new_state = False
    else:
        # Unrecognised account.* event — fall back to the payload's
        # status field so a new Razorpay event we haven't seen yet
        # still drives the flag if its body carries the signal.
        status = (account.get("status") or "").lower()
        new_state = status == "activated"
    if user.razorpay_charges_enabled != new_state:
        user.razorpay_charges_enabled = new_state
        await db.commit()


__all__ = [
    "start_connect_onboarding",
    "refresh_account_status",
    "create_checkout_session",
    "parse_webhook_event",
    "record_purchase_from_event",
]
