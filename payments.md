# Reader Subscriptions — End-to-End Plan

The InkSpaceX app already has **author-side Razorpay Route** (one-time book purchases, with platform fee + Route transfer to author). This doc plans the **reader-side monthly subscription** — `₹199/month` recurring, billed by Razorpay Subscriptions API.

The current subscription page (`lib/ui/pages/subscription_page.dart`) is a static mockup. Goal: make every element on that page real — Active status, next billing date, amount, payment method, Manage payment method, Change plan, End subscription, View billing history. Plus the missing first-time subscribe flow (the screen is shown to users who are already "Active", but there's no way for them to actually get there today).

## Architecture overview

```
 ┌─────────────────────┐                ┌───────────────────────────┐
 │  Flutter client     │  HTTPS         │  FastAPI backend          │
 │                     ├────────────────►  /api/subscriptions/*     │
 │  SubscriptionPage   │                │  (auth via JWT)           │
 │  BillingHistoryPage │                │                           │
 │  SubscriptionProvider                │  ┌─────────────────────┐  │
 │                     ◄────────────────┤  │ app/subscriptions.py│  │
 └──────────┬──────────┘  JSON          │  │ (Razorpay wrapper)  │  │
            │                            │  └──────┬──────────────┘  │
            │ url_launcher              │         │                  │
            ▼                            └─────────┼──────────────────┘
 ┌─────────────────────┐                          │
 │ Razorpay-hosted     │                          │ HTTPS
 │ subscription URL    │                          ▼
 │ (UPI / cards / NB)  │                  ┌────────────────┐
 └──────────┬──────────┘                  │   Razorpay     │
            │                              │   /v1/*        │
            │ webhook                      └───────┬────────┘
            ▼                                      │
 ┌─────────────────────┐                          │
 │ /api/payments/      ◄───── subscription.* ─────┘
 │   webhook (existing)│       events
 └─────────────────────┘
```

The webhook endpoint **stays at `/api/payments/webhook`** (same path Razorpay is already configured against). Subscription events are routed by `event.event` name to a new dispatcher inside `app/payments.py`.

All Razorpay interaction is server-side. The Flutter client only opens hosted URLs — no `razorpay_flutter` SDK.

## Razorpay primitives we use

| Primitive | What it is | How we use it |
|---|---|---|
| **Plan** | `₹199/month` template | One-time setup. ID stored in `RAZORPAY_PLAN_ID_MONTHLY` env var. |
| **Customer** | Razorpay's record of a buyer | Lazily created on first subscribe. ID stored on `users.razorpay_customer_id`. |
| **Subscription** | Linked Plan + Customer + auth + recurring billing schedule | Created when user taps Subscribe. ID stored on `subscriptions.razorpay_subscription_id`. |
| **Invoice** | One per charge cycle | Pulled on demand for billing history; we don't mirror them locally except by reference. |

States of a Razorpay subscription (we mirror them locally):

`created → authenticated → active → (paused | halted | cancelled | completed)`

- `created` — subscription exists, user hasn't authorized yet (hasn't visited `short_url`).
- `authenticated` — user authorized payment but first charge hasn't landed.
- `active` — recurring; latest charge captured.
- `pending` — a charge failed; Razorpay will retry.
- `halted` — too many failed retries; user must update payment method.
- `cancelled` — user or we cancelled. Stays active until `current_end` if `cancel_at_cycle_end=true`.
- `completed` — `total_count` cycles done (we use `total_count=120` ≈ 10 years; effectively perpetual).

## Database schema

### `users` — add three columns

```sql
ALTER TABLE users ADD COLUMN razorpay_customer_id VARCHAR(64);
ALTER TABLE users ADD COLUMN active_subscription_id UUID; -- FK to subscriptions.id
ALTER TABLE users ADD COLUMN subscription_status VARCHAR(32); -- mirrors latest subscriptions.status
```

`active_subscription_id` is a denormalized pointer to the user's current/most-recent subscription row so the hot-path "is this user subscribed?" check is one row read on `users`, no join. Set to NULL when the subscription ends; set to the new row id when they resubscribe.

### `subscriptions` — new table

```sql
CREATE TABLE subscriptions (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    razorpay_subscription_id VARCHAR(64) NOT NULL UNIQUE,
    razorpay_customer_id VARCHAR(64) NOT NULL,
    razorpay_plan_id VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL,            -- created/authenticated/active/pending/halted/cancelled/completed
    short_url TEXT,                         -- hosted Razorpay payment page; cleared once status=active
    current_start TIMESTAMPTZ,              -- start of current billing cycle
    current_end TIMESTAMPTZ,                -- end of current billing cycle (== next charge date)
    charge_at TIMESTAMPTZ,                  -- next scheduled charge timestamp from Razorpay
    cancel_at_cycle_end BOOLEAN NOT NULL DEFAULT FALSE,
    ended_at TIMESTAMPTZ,                   -- when status moved to cancelled/completed
    paid_count INTEGER NOT NULL DEFAULT 0,  -- number of successful charges so far
    total_count INTEGER NOT NULL,           -- plan length in cycles (we use 120)
    amount_cents INTEGER NOT NULL,          -- plan price (₹199 = 19900 paise)
    currency VARCHAR(8) NOT NULL DEFAULT 'inr',
    plan_label VARCHAR(64) NOT NULL DEFAULT '1 month',  -- shown on UI
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ix_subscriptions_user_status ON subscriptions (user_id, status);
CREATE INDEX ix_subscriptions_status ON subscriptions (status);
```

### `subscription_invoices` — new table

We pull invoices from Razorpay on demand for the history page, but cache them locally so the page is fast and offline-tolerant. The webhook (subscription.charged → invoice attached) writes here.

```sql
CREATE TABLE subscription_invoices (
    id UUID PRIMARY KEY,
    subscription_id UUID NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    razorpay_invoice_id VARCHAR(64) NOT NULL UNIQUE,
    razorpay_payment_id VARCHAR(64),
    status VARCHAR(32) NOT NULL,            -- issued/paid/cancelled/expired
    amount_cents INTEGER NOT NULL,
    currency VARCHAR(8) NOT NULL DEFAULT 'inr',
    billing_period_start TIMESTAMPTZ,
    billing_period_end TIMESTAMPTZ,
    paid_at TIMESTAMPTZ,
    short_url TEXT,                         -- receipt URL (Razorpay-hosted PDF)
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ix_subscription_invoices_user_created ON subscription_invoices (user_id, created_at DESC);
```

## REST API contract

All endpoints under `/api/subscriptions/*`. JWT auth via `get_current_user`.

### `GET /api/subscriptions/me` → `SubscriptionMeResponse`

Returns the caller's current subscription state. Used by `SubscriptionPage` to render real data.

```json
{
  "status": "active",                      // none/created/authenticated/active/pending/halted/cancelled/completed
  "plan_label": "1 month",
  "amount_cents": 19900,
  "currency": "inr",
  "current_period_end": "2026-06-12T00:00:00Z",
  "cancel_at_cycle_end": false,
  "payment_method": "Razorpay",
  "short_url": null,                       // populated if user needs to authorize (status created/authenticated)
  "manage_url": null                       // populated when status=active — Razorpay customer-portal-like link
}
```

`status="none"` means the user has never subscribed (or fully ended their subscription). The page shows a Subscribe CTA in this case.

### `POST /api/subscriptions` → `StartSubscriptionResponse`

Create a new Razorpay subscription. Returns the hosted `short_url` for the client to open. Idempotent: if user already has an active or pending-authorization subscription, returns its existing short_url.

```json
{ "subscription_id": "sub_<uuid>", "short_url": "https://rzp.io/i/..." }
```

Server actions:
1. If user has `razorpay_customer_id == NULL`, call `POST /v1/customers` to mint one. Store on user.
2. Call `POST /v1/subscriptions` with `plan_id=<RAZORPAY_PLAN_ID_MONTHLY>`, `total_count=120`, `customer_notify=1`, `notes={user_id}`.
3. Insert row into `subscriptions` table with status=`created`, short_url=response.short_url.
4. Set `users.active_subscription_id` = new row id.

### `GET /api/subscriptions/history` → `BillingHistoryResponse`

```json
{
  "items": [
    {
      "id": "inv_<uuid>",
      "amount_cents": 19900,
      "currency": "inr",
      "status": "paid",
      "billing_period_start": "2026-04-22T00:00:00Z",
      "billing_period_end": "2026-05-22T00:00:00Z",
      "paid_at": "2026-04-22T08:31:22Z",
      "receipt_url": "https://invoice.razorpay.com/i/..."
    },
    ...
  ]
}
```

Returns local `subscription_invoices` rows for the caller, newest first, capped at 50. The webhook keeps this fresh; on the first load after subscribing, we also lazily pull from Razorpay's `/v1/invoices?subscription_id=...` to backfill anything the webhook hasn't landed yet.

### `POST /api/subscriptions/cancel` → `CancelResponse`

Body: `{ "immediate": false }` (default false = cancel at end of current cycle).

Calls `POST /v1/subscriptions/{id}/cancel` with `cancel_at_cycle_end=1` (the default) or `cancel_at_cycle_end=0` if immediate. Mirrors `cancel_at_cycle_end` onto the local row.

```json
{ "status": "cancelled", "cancel_at_cycle_end": true, "ends_at": "2026-06-22T00:00:00Z" }
```

### `POST /api/subscriptions/change-plan` → not in v1

We ship only the `₹199/month` plan. Add a `Change plan` tile that says "Only one plan available at the moment" sheet on tap — keeps the surface honest. (Real implementation deferred until we have an annual plan.)

### `GET /api/subscriptions/manage-payment-method` → `ManagePaymentResponse`

Returns a hosted Razorpay URL where the user can update their saved card / UPI. Razorpay surfaces this via `/v1/subscriptions/{id}` → `short_url` (re-authorize flow) when status=`halted`; otherwise we direct them to update their Customer's saved tokens. We'll just return the subscription's short_url for now.

```json
{ "url": "https://rzp.io/i/..." }
```

## Webhook events (extension to existing /api/payments/webhook)

In `app/payments.py`'s `record_purchase_from_event`, add a dispatcher: if `etype.startswith("subscription.")` or `etype.startswith("invoice.")`, call `_apply_subscription_event(event, etype, db)` instead of the existing payment.captured / account.* logic.

Events to handle:

| Event | Action |
|---|---|
| `subscription.authenticated` | Update local row status=`authenticated`. |
| `subscription.activated` | status=`active`. Clear `short_url`. Populate `current_start/current_end/charge_at/paid_count`. |
| `subscription.charged` | Bump `paid_count`. Refresh `current_start/current_end/charge_at`. Pull invoice from event payload and insert into `subscription_invoices` (idempotent on `razorpay_invoice_id`). |
| `subscription.pending` | status=`pending`. |
| `subscription.halted` | status=`halted`. User must re-auth. |
| `subscription.cancelled` | status=`cancelled`, `ended_at=now()`. If user's `active_subscription_id == this row.id`, set both `users.active_subscription_id=NULL` and `users.subscription_status='cancelled'`. |
| `subscription.completed` | status=`completed`, `ended_at=now()`. Same user-row cleanup. |
| `subscription.paused` / `subscription.resumed` | Mirror status. (Not exposed in UI yet but record for completeness.) |
| `invoice.paid` | Already covered by subscription.charged in most cases; treat as upsert. |

Webhook is idempotent on `razorpay_subscription_id` lookups + `razorpay_invoice_id` uniqueness. Replays no-op.

## Razorpay Plan (one-time setup)

`backend/scripts/create_razorpay_plan.py` — idempotent script. Calls `POST /v1/plans`:

```json
{
  "period": "monthly",
  "interval": 1,
  "item": {
    "name": "InkSpaceX Monthly",
    "description": "Unlimited books, audiobooks, and offline access",
    "amount": 19900,
    "currency": "INR"
  },
  "notes": { "label": "1 month", "tier": "reader" }
}
```

Prints the `plan_<id>`. Operator copies it into `RAZORPAY_PLAN_ID_MONTHLY` env var in `backend/.env`. Safe to re-run — checks first for an existing plan with `notes.label="1 month"` and prints it instead of creating a duplicate.

## Flutter client

### New files

- `lib/services/api/api_subscription_service.dart` — typed wrapper over the 4 endpoints above. Models: `SubscriptionMe`, `BillingInvoice`, `CancelResult`.
- `lib/provider/subscription_provider.dart` — ChangeNotifier holding `SubscriptionMe?`. Methods: `refresh()`, `startSubscribe()` (returns short_url), `cancel({required bool immediate})`, `manage()` (returns url).
- `lib/ui/pages/billing_history_page.dart` — list of invoices, each row tappable to open receipt PDF via `url_launcher`.

### Rewrite `subscription_page.dart`

- On `initState`, call `provider.refresh()`.
- If `status == "none"`: render a Subscribe CTA card. Tap → `startSubscribe()` → `launchUrl(shortUrl, externalApplication)`. On return (app resumed), `refresh()` until status flips to `active` (poll every 2s for up to 60s).
- If `status == "active"`: render the existing card with **real** data from `me`. Next billing date = `current_period_end` formatted. Amount = `₹{amount_cents/100}/month`. Payment method = `me.payment_method`.
- If `status == "created"` / `"authenticated"`: show "Authorization pending" state with a "Complete payment" CTA that re-opens `short_url`.
- If `status == "halted"`: show "Payment failed — update payment method" CTA pointing at `manage()` URL.
- If `cancel_at_cycle_end == true`: replace `Active` heading with `Ends {date}` and grey out the End subscription button.

Wire up tiles:
- **Manage payment method** → `manage()` → `launchUrl`.
- **Change plan** → bottom sheet "Only one plan available at the moment."
- **End subscription** → confirm sheet "Cancel at end of cycle ({date}) or end immediately?" Two buttons. Pick → `cancel(immediate=...)` → `refresh()`.
- **View billing history** → `Navigator.push` to `BillingHistoryPage`.

### Routing

`lib/router.dart` add:

```dart
GoRoute(
  path: '/subscription/history',
  builder: (_, _) => const BillingHistoryPage(),
),
```

### Provider wiring

`SubscriptionProvider` is registered in `lib/main.dart` alongside the existing providers. The Profile Hub page (where the "Subscription" link lives) gets a small badge: read `provider.me?.status` and show "Active" / "Inactive" next to the menu item.

## Env config (backend)

Add to `app/config.py`:

```python
razorpay_plan_id_monthly: str = ""  # set once via scripts/create_razorpay_plan.py
```

`/api/subscriptions/*` returns 503 when `razorpay_plan_id_monthly` is empty so a misconfigured deployment fails loudly.

## Work split (5 parallel Opus 4.7 agents)

| Agent | Scope | Files |
|---|---|---|
| **A1 — Data layer** | Subscription + Invoice models, migration, user-table additions, Razorpay plan setup script, config field | `backend/app/models/subscription.py` (new), `backend/app/models/subscription_invoice.py` (new), `backend/app/models/user.py` (edit), `backend/app/models/__init__.py` (edit), `backend/alembic/versions/20260513_02_subscriptions.py` (new), `backend/scripts/create_razorpay_plan.py` (new), `backend/app/config.py` (edit) |
| **A2 — Razorpay service layer** | Pure Razorpay wrappers (no DB). create_subscription, cancel_subscription, fetch_subscription, list_invoices_for_subscription, create_or_get_customer | `backend/app/subscriptions.py` (new) |
| **A3 — API routes + webhook extension** | REST endpoints under `/api/subscriptions/*` + extend `app/payments.py` webhook to dispatch subscription.* and invoice.* events | `backend/app/routers/subscriptions.py` (new), `backend/app/payments.py` (edit `record_purchase_from_event`), `backend/app/main.py` (include router) |
| **A4 — Flutter API + provider** | API service, models, ChangeNotifier provider, main.dart registration | `lib/services/api/api_subscription_service.dart` (new), `lib/provider/subscription_provider.dart` (new), `lib/main.dart` (edit MultiProvider) |
| **A5 — Flutter UI** | Rewrite subscription page, new billing history page, router route, deep-link return polling | `lib/ui/pages/subscription_page.dart` (rewrite), `lib/ui/pages/billing_history_page.dart` (new), `lib/router.dart` (edit) |

Interfaces are pinned in this doc — agents implement against the contracts above, not against each other's code.

## Acceptance criteria

End-to-end test flow:

1. New user opens `/subscription` → sees Subscribe CTA card.
2. Taps Subscribe → Razorpay-hosted page opens in browser.
3. Pays with Razorpay test UPI (`success@razorpay`).
4. Returns to app → page auto-refreshes → shows Active, next billing date one month out, amount ₹199/month, Razorpay payment method.
5. Webhook lands `subscription.charged` → `subscription_invoices` gets one row.
6. Open Billing history → see one paid invoice with receipt URL.
7. Tap End subscription → choose "at end of cycle" → page reflows to "Ends {date}", End subscription tile greys out.
8. Razorpay test cron fires next charge → another `subscription_invoices` row.
9. Tap End subscription → immediate → page reflows to Subscribe CTA.

All without any UI showing hardcoded strings — every value comes from the backend.
