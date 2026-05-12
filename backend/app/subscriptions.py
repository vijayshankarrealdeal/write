"""Razorpay Subscriptions plumbing — thin wrappers over the Razorpay
Subscriptions / Customers / Invoices APIs.

This module is intentionally pure: it does *no* database I/O and *no*
authorization. Every function is a single Razorpay round-trip wrapped
in the same `_friendly_error` / `HTTPException(409)` translation
pattern used by `app.payments`. Callers (the routers in
`app.routers.subscriptions` and the webhook dispatcher in
`app.payments`) are responsible for:

* verifying the caller owns the relevant subscription,
* persisting the returned ids onto our `subscriptions` /
  `subscription_invoices` rows,
* writing back `users.razorpay_customer_id` after
  `create_or_get_customer` mints a new id.

Six external surfaces, all named after the router action that calls
them:

* `create_or_get_customer(user)` — used by `POST /api/subscriptions`
  before it creates a subscription, to make sure the user has a
  Razorpay customer id. Returns the existing one if already set,
  otherwise mints a new one via `POST /v1/customers`.
* `create_subscription(plan_id, customer_id, total_count, user_id, ...)`
  — used by `POST /api/subscriptions`. Returns the raw Razorpay
  subscription dict (with `id`, `short_url`, `status`,
  `current_start`, `current_end`, `charge_at`, etc.) so the router
  can both persist it and hand `short_url` back to the client.
* `fetch_subscription(subscription_id)` — used by `GET
  /api/subscriptions/me` for a fresh read when the local row looks
  stale, and by the webhook dispatcher when an event payload doesn't
  carry the full subscription entity.
* `cancel_subscription(subscription_id, *, immediate)` — used by
  `POST /api/subscriptions/cancel`. `immediate=False` cancels at the
  end of the current billing cycle (Razorpay's default behaviour);
  `immediate=True` ends the subscription right away.
* `list_invoices_for_subscription(subscription_id, ...)` — used by
  `GET /api/subscriptions/history` to backfill any invoices the
  webhook hasn't landed yet. Returns the raw `items` list from the
  Razorpay response.
* `fetch_invoice(invoice_id)` — used by the webhook handler if the
  event payload's invoice envelope is too thin to populate a local
  `subscription_invoices` row.
"""
from __future__ import annotations

from fastapi import HTTPException

from app.config import settings
from app.models.user import User


# Initialise the SDK lazily so a missing key (or a missing `razorpay`
# package on a dev box that doesn't talk to Razorpay at all) doesn't
# blow up the process at import time — the routers raise 503 in that
# case so the rest of the API keeps responding. This is also why we
# import the module inside the helper instead of at the top. Mirrors
# `app.payments._razorpay` deliberately so a future SDK swap touches
# both files the same way.
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


def _friendly_error(exc: Exception) -> str:
    """Translate a Razorpay-raised exception into a user-facing message.

    Most Razorpay rejections (validation, duplicate, plan-not-found)
    are useful verbatim — they tell the operator what to fix. Two
    subscription-specific opaque errors get rewritten:

    * "Subscriptions feature is not enabled" — appears on accounts
      where Razorpay Subscriptions hasn't been activated on the
      dashboard yet. Direct the user back to a calmer error.
    * "plan_id is invalid" — usually means the `RAZORPAY_PLAN_ID_MONTHLY`
      env var points at a deleted/sandbox plan. Surface a hint.
    """
    raw = str(exc)
    if "Subscriptions feature is not enabled" in raw:
        return (
            "Subscriptions are not enabled on this deployment yet. "
            "Please try again later."
        )
    if "plan_id" in raw and "invalid" in raw.lower():
        return (
            "The subscription plan is misconfigured on the server. "
            "Please contact support."
        )
    return raw


def create_or_get_customer(user: User) -> str:
    """Return a Razorpay customer id for [user], minting one if needed.

    Called from `POST /api/subscriptions` before a subscription is
    created. If `user.razorpay_customer_id` is already set we trust
    it and return immediately — we never re-mint, because we'd lose
    continuity of saved tokens.

    When the local pointer is null but Razorpay already has a customer
    on this email (e.g. the user signed up before this column existed,
    or a prior attempt minted a customer before failing on the
    subscription create), we recover by searching customers by email
    and returning that id. That keeps the flow idempotent across
    deploys and prevents the 409 "Customer already exists" loop A2's
    original code hit because it passed the wrong key (`fail_if_exists`
    is not a Razorpay parameter — the actual flag is `fail_existing`
    and it must be the STRING `"0"`, not the bool `False`, which
    Razorpay silently ignores).

    Does *not* persist the returned id; the caller writes it back onto
    the user row inside the same transaction that creates the local
    `subscriptions` row, so a half-success (customer minted, local
    row insert fails) doesn't leave a stranded id on the user.
    """
    existing = getattr(user, "razorpay_customer_id", None)
    if existing:
        return existing
    rzp = _razorpay()
    body = {
        "email": user.email,
        "name": user.name or "Reader",
        # String "0" is intentional — Razorpay coerces "0" → return the
        # existing customer, anything else (including bool False) →
        # 400/409 on duplicate email.
        "fail_existing": "0",
        "notes": {
            "user_id": str(user.id),
        },
    }
    try:
        customer = rzp.customer.create(body)
        return customer["id"]
    except Exception as exc:
        message = str(exc)
        if "already exists" not in message.lower():
            raise HTTPException(
                status_code=409, detail=_friendly_error(exc)
            )

    # Fallback path: SDK still raised despite `fail_existing="0"` (we've
    # seen this when the email was registered under a slightly different
    # case, or on older SDK versions). Look the customer up by email
    # and reuse its id.
    try:
        listing = rzp.customer.all({"email": user.email, "count": 5})
    except Exception as exc:
        raise HTTPException(status_code=409, detail=_friendly_error(exc))
    for item in listing.get("items", []) or []:
        if (item.get("email") or "").lower() == user.email.lower():
            return item["id"]
    # Razorpay told us the customer exists but we can't find it — surface
    # the original "already exists" message so the caller sees something
    # actionable instead of a generic 500.
    raise HTTPException(
        status_code=409,
        detail=(
            "Razorpay reports a customer already exists for this email "
            "but we couldn't look it up. Please contact support."
        ),
    )


def create_subscription(
    plan_id: str,
    customer_id: str,
    total_count: int,
    user_id: str,
    *,
    notify_email: bool = True,
) -> dict:
    """Create a Razorpay subscription and return the raw response dict.

    Called from `POST /api/subscriptions`. The returned dict carries
    everything the router needs to populate the local `subscriptions`
    row: `id`, `short_url` (the hosted authorization page the client
    opens via `url_launcher`), `status` (initially `created`),
    `current_start`/`current_end`/`charge_at`, and the echoed
    `plan_id` / `customer_id`.

    `notes={"user_id": user_id}` is what lets the webhook dispatcher
    correlate `subscription.*` events back to our local row without
    an extra round-trip. `customer_notify=1` asks Razorpay to email
    the reader the standard "your subscription is set up" message —
    we keep it on by default but expose `notify_email` so a future
    silent-resubscribe flow can suppress the duplicate notification.
    """
    rzp = _razorpay()
    try:
        return rzp.subscription.create({
            "plan_id": plan_id,
            "customer_id": customer_id,
            "total_count": total_count,
            "customer_notify": 1 if notify_email else 0,
            "notes": {
                "user_id": user_id,
            },
        })
    except Exception as exc:
        raise HTTPException(status_code=409, detail=_friendly_error(exc))


def fetch_subscription(subscription_id: str) -> dict:
    """Re-fetch the canonical subscription state from Razorpay.

    Called from `GET /api/subscriptions/me` when the local row's
    `updated_at` is older than our staleness threshold, and from the
    webhook dispatcher when an event payload doesn't include the
    full subscription entity (e.g. some `invoice.paid` events carry
    only the invoice envelope). The returned dict matches Razorpay's
    `GET /v1/subscriptions/{id}` shape exactly.
    """
    rzp = _razorpay()
    try:
        return rzp.subscription.fetch(subscription_id)
    except Exception as exc:
        raise HTTPException(status_code=409, detail=_friendly_error(exc))


def cancel_subscription(subscription_id: str, *, immediate: bool) -> dict:
    """Cancel a Razorpay subscription, returning the updated entity.

    Called from `POST /api/subscriptions/cancel`. With `immediate=False`
    (the default exposed by the router) Razorpay marks the
    subscription `cancelled` but keeps it billing-active until
    `current_end`, so the reader keeps access for the cycle they
    already paid for. With `immediate=True` the subscription stops
    right away and no further charges are scheduled.

    The router mirrors the response onto the local row:
    `cancel_at_cycle_end`, `status`, `ended_at`.
    """
    rzp = _razorpay()
    try:
        return rzp.subscription.cancel(
            subscription_id,
            {"cancel_at_cycle_end": 0 if immediate else 1},
        )
    except Exception as exc:
        raise HTTPException(status_code=409, detail=_friendly_error(exc))


def list_invoices_for_subscription(
    subscription_id: str, *, count: int = 50
) -> list[dict]:
    """Return up to [count] invoices for [subscription_id], newest first.

    Called from `GET /api/subscriptions/history` to lazily backfill
    any invoices the webhook hasn't landed yet — most of the time the
    local `subscription_invoices` rows are authoritative, but on
    first load right after subscribing the webhook may not have
    landed `subscription.charged` yet and the user expects to see
    the invoice they just paid. Returns the raw `items` list from
    Razorpay's `GET /v1/invoices?subscription_id=...` response.
    """
    rzp = _razorpay()
    try:
        resp = rzp.invoice.all({
            "subscription_id": subscription_id,
            "count": count,
        })
    except Exception as exc:
        raise HTTPException(status_code=409, detail=_friendly_error(exc))
    return list(resp.get("items") or [])


def fetch_invoice(invoice_id: str) -> dict:
    """Re-fetch a single invoice from Razorpay.

    Called from the webhook dispatcher when an `invoice.*` event's
    payload doesn't include enough fields to populate a local
    `subscription_invoices` row (e.g. an `invoice.paid` event that
    omits `billing_start`/`billing_end`). The returned dict matches
    Razorpay's `GET /v1/invoices/{id}` shape.
    """
    rzp = _razorpay()
    try:
        return rzp.invoice.fetch(invoice_id)
    except Exception as exc:
        raise HTTPException(status_code=409, detail=_friendly_error(exc))


__all__ = [
    "create_or_get_customer",
    "create_subscription",
    "fetch_subscription",
    "cancel_subscription",
    "list_invoices_for_subscription",
    "fetch_invoice",
]
