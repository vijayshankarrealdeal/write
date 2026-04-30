# Analytics implementation plan

End-to-end user-behaviour analytics for InkSpaceX. Events flow from the
Flutter app to a Postgres-backed FastAPI ingest, optimised for the
question "what did this user do, in what order?".

This document tracks what landed in the initial PR vs. what's deferred.
Update it whenever scope changes — it's the single source of truth for
"is feature X built yet?".

---

## Phase 1 — schema + migration + backend endpoint

**Shipped:**

- `backend/app/models/analytics.py` — adds `AnalyticsEvent` SQLAlchemy
  model. Columns: `id`, `user_id` (FK users, nullable, ON DELETE SET
  NULL), `client_id`, `session_id`, `event_name`, `screen`, `action`,
  `entity_type`, `entity_id`, `source_screen`, `duration_ms`,
  `properties` (JSONB), `client_ts`, `server_ts`, `user_agent`, `ip`
  (INET).
- `backend/alembic/versions/20260430_01_analytics_events.py` — Alembic
  migration that creates the `analytics_events` table with five
  indexes: `(user_id, server_ts)`, `(event_name, server_ts)`,
  `(client_id, server_ts)`, `(session_id, server_ts)`, and a GIN
  index on `properties` so `properties @> '{...}'` queries are cheap.
  Runs automatically via the Dockerfile's `alembic upgrade head`.
- `backend/app/schemas/analytics.py` — Pydantic `AnalyticsEventIn`,
  `AnalyticsBatchIn`, `AnalyticsIngestResponse`. Per-event
  `properties` capped at 4 KiB; per-batch `events` capped at 100.
- `backend/app/auth/deps.py` — adds `get_optional_user` so analytics
  endpoints can accept anonymous traffic while still attaching
  `user_id` when a JWT is present.
- `backend/app/routers/analytics.py` — `POST /api/analytics/events`.
  Inserts the batch, captures `user_agent`/`ip`, and (for
  authenticated requests) runs the identity-stitch UPDATE described
  in Phase 5.
- `backend/app/main.py` — wires the router into the FastAPI app.
- `backend/app/models/__init__.py` — exports `AnalyticsEvent`.

**Not in this PR:**

- No partitioning on `analytics_events` yet. Once volume crosses
  ~10–50 M rows we'll want monthly time partitions plus a retention
  job that drops the oldest. Until then, the GIN + btree indexes are
  enough.
- No background worker / queue between the API and the table — the
  endpoint inserts synchronously. Fine at current scale; revisit if
  ingest QPS becomes a write hotspot on the primary.
- No archival to a warehouse (BigQuery/Snowflake/etc.) — Postgres is
  it. Adding a CDC tail is a future PR.

---

## Phase 2 — frontend `AnalyticsService` (buffering, offline queue, sessions)

**Shipped:**

- `lib/services/analytics_service.dart` — singleton owned by `main.dart`.
  - In-memory buffer flushed every 5s (timer) or every 20 events
    (size threshold), whichever comes first.
  - On flush failure, the entire pending set spills to a Hive box
    (`analytics_queue`); the next successful flush drains it. Queue
    is capped at 1000 events — older entries are dropped if the cap
    is hit, on the principle that losing some signal beats filling
    the user's disk.
  - Stable `client_id` UUID generated on first run and persisted in
    the Hive box; survives logout/login (this is what the backend
    uses to stitch anonymous events to the user — see Phase 5).
  - Per-launch `session_id` UUID; rolled when the app foregrounds
    after >30 minutes idle.
  - `enabled` flag wired to `kReleaseMode` by default; override with
    `--dart-define=ANALYTICS_ENABLED=true|false`.
  - Test seam: `initForTest(poster:)` accepts a fake post function so
    the buffer/queue can be exercised without booting `ApiClient`.

**Not in this PR:**

- No exponential backoff on retries — failed flushes wait until the
  next timer tick (5s) or the next size-threshold trigger. Good
  enough at current scale; revisit if we observe thrash against an
  outage.
- No de-duplication of events. If the client crashes between a
  successful insert and clearing the disk queue, the same events can
  re-send on next launch. Backend has no idempotency key today.

---

## Phase 3 — auto-capture (NavigatorObserver, app lifecycle)

**Shipped:**

- `lib/services/analytics_observer.dart` — `AnalyticsNavigatorObserver`
  fires `screen_viewed` on push/pop/replace, populating `screen` from
  `route.settings.name` (which `go_router` sets to the matched route
  template, e.g. `/post/:id`).
- `lib/router.dart` — registers the observer on the root `GoRouter`.
- `lib/main.dart` — `MyApp` now `StatefulWidget` with
  `WidgetsBindingObserver`. `didChangeAppLifecycleState` calls
  `onAppForegrounded` / `onAppBackgrounded` on the analytics service,
  which fire `app_foregrounded` / `app_backgrounded` events and
  flush the buffer on background.

**Not in this PR:**

- No time-on-screen measurement yet. The observer captures entry
  events but doesn't pair them with exit events to compute dwell.
  Easy follow-up: stash a `screen_started_at` per route on push,
  emit `screen_exited` with `duration_ms` on pop/replace.
- No web-specific tab-visibility hook (`document.visibilitychange`).
  Mobile's lifecycle covers the equivalent on app, but a backgrounded
  browser tab won't fire `app_backgrounded`. Web users get whatever
  the timer batches before the tab is hidden.

---

## Phase 4 — semantic event instrumentation across screens

**Shipped (semantic events called via `AnalyticsService.instance.track(...)`):**

- `auth_login_viewed` — `lib/ui/auth/login_page.dart` initState.
- `auth_login_submitted` / `auth_login_succeeded` / `auth_login_failed` —
  `lib/provider/auth_provider.dart#login`.
- `auth_signup_viewed` — `lib/ui/auth/signup_page.dart` initState.
- `auth_signup_submitted` / `signup_completed` / `auth_signup_failed` —
  `lib/provider/auth_provider.dart#signup`.
- `auth_google_clicked` / `auth_google_succeeded` / `auth_google_failed` —
  `lib/provider/auth_provider.dart#signInWithGoogle`.
- `auth_logout` — `lib/provider/auth_provider.dart#logout`.
- `post_viewed` — `lib/ui/pages/post_detail_page.dart` initState.
- `profile_viewed` (author) — `lib/ui/pages/author_profile_page.dart`
  initState.
- `app_started` — `lib/main.dart` immediately after `AnalyticsService.init`.
- `app_foregrounded` / `app_backgrounded` — `lib/main.dart` lifecycle
  observer.
- Auto-capture `screen_viewed` for every navigation via the
  NavigatorObserver (Phase 3) — covers settings, drafts, search,
  notifications, bookmarks, etc. without explicit instrumentation.

**Not in this PR (auto-capture only — semantic event still TODO):**

- `post_liked` / `post_unliked` — feed/post-detail like buttons.
- `post_saved` / `post_unsaved` — save toggle.
- `post_bookmarked` / `post_unbookmarked` — bookmark toggle.
- `post_deleted` — author delete flow.
- `post_comment_added` — comment submission.
- `post_shared` — share button.
- `editor_draft_saved` / `editor_published` — editor screen.
- `feed_refreshed` — pull-to-refresh.
- `search_submitted` — explicit search action (auto-capture covers
  view).
- `subscription_*` and `bookshelf_*` flows.
- `forgot_password_*` flow.
- `onboarding_completed` — exists as `completeOnboarding` in
  AuthProvider but isn't tracked yet.

These are mechanical adds — pick a method, drop a `track(...)` line.
Doing them all in this PR would balloon the diff; subsequent PRs can
chip away at the list as they touch each surface.

---

## Phase 5 — anonymous → identified stitching

**Shipped:**

- Backend ingest (`backend/app/routers/analytics.py`) runs an
  idempotent UPDATE on every authenticated batch: for each
  `client_id` in the batch, set `user_id = $auth_user` on any prior
  rows where `user_id IS NULL AND client_id = $cid`. After the first
  authenticated batch the UPDATE matches zero rows. The response
  reports how many rows were stitched so we can sanity-check from
  curl.
- Frontend (`AuthProvider`) sets the analytics service's user id on
  login/signup/Google success, and clears it on logout. The
  `properties.user_id` field is purely advisory — backend trusts the
  JWT, not the client-supplied value.
- `setUserId(null)` on logout — subsequent anonymous events use the
  same `client_id` (so they'd stitch onto whoever logs in next on
  this device), but a fresh session ensures funnels don't bleed
  across the boundary.

**Not in this PR:**

- Shared-device caveat: if two users sign in on the same physical
  device, the second login stitches the first user's pre-second-login
  anonymous events under the second user. Acceptable trade-off given
  most "anonymous" rows are landing-page noise; revisit if it shows
  up in the data.

---

## Phase 6 — tests, docs, env flag

**Shipped:**

- `backend/tests/test_analytics.py` — schema-only tests (no Postgres
  boot) pinning the `analytics_events` columns, the indexes, the
  Pydantic batch bounds, the 4 KiB properties cap, and the router's
  use of the optional auth dep.
- `test/analytics_service_test.dart` — Hive-backed integration test
  for the service: track→flush→poster, failed-flush→disk-queue→retry,
  client_id persists across reinit, disabled mode is a no-op.
- Env flag — `--dart-define=ANALYTICS_ENABLED=true|false` overrides
  the default (release: on, debug: off). Documented in this file and
  in the service docstring.
- README — gets a short "Analytics" section pointing at this plan.
- Inline doc on the model, schema, router, and service explains the
  "why" of each design decision.

**Not in this PR:**

- No end-to-end test that actually round-trips through Postgres. The
  rest of `backend/tests/` follows the same schema-only pattern, so
  adding integration coverage is a separate effort that touches the
  test fixture story too.
- No backend test for the stitching UPDATE itself — that needs a real
  database. Manually verified for now.

---

## What's left (at a glance)

### Round 2 — shipped

Pulled the data-quality wins forward (semantic events + dwell time +
real DB-backed test + a small web bonus). Bigger infra commitments
stay deferred.

**Shipped:**

- **a. Semantic events** wired inside the actual handlers (not on
  screens that don't exist):
  - `post_liked` / `post_unliked` —
    `lib/provider/auth_provider.dart#toggleLike`.
  - `post_favorited` / `post_unfavorited` —
    `lib/provider/auth_provider.dart#toggleFavorite` (the "save"
    affordance).
  - `bookmark_added` / `bookmark_removed` —
    `lib/provider/bookmark_provider.dart#addBookmark` /
    `deleteBookmark`.
  - `post_comment_added` / `post_comment_deleted` —
    `lib/provider/feed_provider.dart#addComment` / `deleteComment`.
  - `post_link_copied` — `_shareItem` in `lib/ui/app/feed.dart` and
    the `Clipboard.setData` path in
    `lib/ui/pages/post_detail_page.dart`.
  - `editor_opened` — `lib/ui/pages/editior_page.dart#initState`.
  - `editor_draft_saved` (when `is_draft=true`) /
    `post_published` / `post_publish_failed` —
    `lib/ui/pages/publish_page.dart#_publish`.
  - `search_submitted` + `search_results_loaded` —
    `lib/ui/app/search_page.dart#_runSearch`. Properties carry
    `query_length` and `scope` — never the raw query, so a partial
    title or someone's name doesn't leak into analytics.
  - `post_deleted` — `lib/provider/editor_provider.dart#deleteBook`.
  - `onboarding_completed` —
    `lib/provider/auth_provider.dart#completeOnboarding`.
- **b. Dwell-time pairing** in `lib/services/analytics_observer.dart`.
  The observer holds `_activeName`/`_activeStartedAt` and on every
  push/pop/replace emits a `screen_left` event for the route the user
  is leaving with `duration_ms`. `source_screen` on `screen_left`
  points at where they're going next (the mirror of `screen_viewed`'s
  `source_screen`, which points at where they came from), so funnel
  queries can reconstruct edges from either direction. Pop is
  modelled as a fresh `screen_viewed` for the previous route — each
  foreground appearance gets its own dwell. No per-screen timing
  code needed.
- **c. Backend integration test** —
  `backend/tests/test_analytics_integration.py` boots a Postgres
  container via testcontainers, runs the real `alembic upgrade head`,
  reloads `app.config` + `app.database` so the engine binds to the
  test DB, then exercises `POST /api/analytics/events` twice through
  FastAPI's `TestClient`: one anonymous batch with three events, one
  authenticated batch with the same `client_id` and one event. Asserts
  `stitched_count == 3` on the authed call, then queries the table
  directly to confirm every row now carries `user_id`, then sends a
  third authed batch and asserts `stitched_count == 0`
  (idempotency). Skips cleanly if `testcontainers[postgres]` isn't
  installed or Docker isn't reachable — see
  `backend/requirements-dev.txt`.
- **d. Web tab-visibility flush** —
  `_MyAppState.didChangeAppLifecycleState` now treats
  `AppLifecycleState.hidden` as "flush, don't roll the session". On
  Flutter web the browser fires `hidden` on tab visibility loss and
  this gets the buffer to disk before the OS may reclaim the tab.
  On native it's effectively a no-op since `paused` / `detached`
  already cover the same beat.

**Tests added:**

- `backend/tests/test_analytics_integration.py` — described above.
- `backend/requirements-dev.txt` — declares `testcontainers[postgres]`
  as a test-only dep so production images don't pull it in.
- `test/analytics_service_test.dart` — extra case verifies
  `AnalyticsNavigatorObserver` emits paired `screen_viewed` /
  `screen_left` with positive `duration_ms` and a populated
  `source_screen`.

**Deferred this round (with reasons):**

- **Idempotency on the ingest endpoint.** Wants a client-generated
  event UUID, a unique-on-conflict insert, and a schema migration.
  Surface is bigger than a single feature toggle — its own PR.
- **Partitioning + retention.** Needs an ops decision on partition
  cadence and retention window. Premature at current volume; the
  GIN + btree indexes are still doing the work.
- **Warehouse export.** Depends on a product choice of warehouse
  (BigQuery vs Snowflake vs S3+Athena) before any code.
- **Admin dashboard.** Separate UI/UX surface. The legacy
  `/api/admin/analytics/*` reads cover the older
  `page_visits`/`crash_reports` tables — adding views over the
  new table is a bigger UI commitment than fits here.
- **Exponential backoff on retry.** Marginal; the 5 s timer tick is
  fast enough that an outage doesn't visibly compound.
- **PII-safety lint.** Custom Dart analyzer plugins are real
  infrastructure for a guardrail that mostly catches "user typed
  the wrong key into a literal".

**Still TODO after Round 2:**

- A `post_shared` event for the platform-share path — currently
  only `post_link_copied` (clipboard) is instrumented. The app uses
  `Clipboard.setData` rather than `share_plus` so this is academic
  until a real share sheet ships.
- A `feed_refreshed` event for pull-to-refresh — auto-capture only
  for now; semantic event would let us measure "refresh fatigue".
- Reading-progress events (`section_read_started` / `_completed`) —
  the data is in `reading_progress` already; emitting analytics
  edges around it would unify both signals onto one timeline.
- The deferred items above (idempotency, partitioning, warehouse
  export, admin dashboard, backoff, PII lint) all remain open.

### Original list

1. **Semantic events for the rest of the surface.** Phase 4 covers
   auth + post-viewed + profile-viewed + lifecycle. Like / save /
   bookmark / delete / comment / share / editor / search / onboarding
   are still auto-capture-only.
2. **Time-on-screen / dwell.** NavigatorObserver fires entry, doesn't
   measure exit. Pair the events for `duration_ms`.
3. **Web tab-visibility.** Currently mobile-only lifecycle hooks.
4. **Idempotency on the ingest endpoint.** No de-dupe key — if a
   client double-flushes, double rows.
5. **Partitioning + retention on `analytics_events`.** Future scaling
   concern.
6. **Streaming export to a warehouse** for serious analyst tooling.
7. **An admin dashboard** that actually reads from `analytics_events`
   — right now you'd query Postgres directly. Even a couple of
   built-in funnels (signup → first post, login → 7-day retention)
   would be high-value.
8. **Backend integration test** for stitching — currently relies on
   manual verification + the typed Pydantic surface.
9. **Exponential backoff** on the client retry path; today retries
   wait for the 5 s timer tick.
10. **PII-safety lint** — the contract is "no passwords or tokens in
    `properties`", but nothing enforces it. A `dart analyze` lint
    that flags `track(properties: {... 'password': ...})` literals
    would catch the obvious mistake.
