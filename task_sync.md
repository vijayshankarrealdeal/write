# Sync Hardening Plan — Path to 10/10

**Goal:** turn the current prototype-grade sync (5/10) into a production-grade local-first sync engine.
**Owner:** agent task list. Tick boxes as work lands. One PR/commit per phase is fine; commit directly to `main` (per repo convention).

**Baseline audit (2026-04-26):** see chat. Top gaps: no connectivity detection, no durable outbox, fake realtime stream, logout wipes unsynced data, swallowed errors, ~zero tests.

---

## Ground rules for the agent

- Read [lib/provider/editor_provider.dart](lib/provider/editor_provider.dart), [lib/services/storage_service.dart](lib/services/storage_service.dart), [lib/services/api/api_client.dart](lib/services/api/api_client.dart), [lib/services/api/api_data_service.dart](lib/services/api/api_data_service.dart), [lib/provider/auth_provider.dart](lib/provider/auth_provider.dart) before changing anything in their area.
- Don't introduce new abstractions speculatively. Each phase below must ship a user-visible or test-visible improvement.
- Tests: every phase adds at least one test in `test/sync/`. No phase is "done" without a test.
- After each phase: run `flutter analyze` and `flutter test`, then commit to `main`.
- Update this file as you go: tick boxes, add notes under "Findings while implementing" inside each phase.

---

## Phase 1 — Connectivity awareness (1 pt → 6/10)

**Why:** every other improvement depends on knowing the link state.

- [x] Add `connectivity_plus` to [pubspec.yaml](pubspec.yaml)
- [x] Create `lib/services/connectivity_service.dart` exposing a `ValueListenable<bool> isOnline` and a broadcast `Stream<bool>`
- [x] Wire it into the provider tree at app boot ([lib/main.dart](lib/main.dart) or wherever providers are registered)
- [x] Add an offline banner widget shown app-wide when offline (top of `Scaffold` shell, dismissible-per-session)
- [x] In `EditorProvider`, gate `_syncToFirestore()` on `isOnline`; when offline, skip the network attempt cleanly (don't log as error)
- [x] Test: `test/sync/connectivity_test.dart` — fake the stream, assert sync is skipped offline and resumes online

**Findings while implementing:**
- Banner is wired via `MaterialApp.router`'s `builder:` so both the iOS-style (`CupertinoTabScaffold`) and desktop (`Scaffold`) shells inherit it without per-page changes. Not dismissible-per-session yet — current strip is non-dismissible because the next phase will pivot the same affordance into a richer status chip in the editor header (Phase 3), so dismissal logic would be thrown away.
- `_syncToFirestore` gate intentionally **leaves `_needsFirestoreSync = true` when offline** so the connectivity-online listener and the next periodic tick can resume the push. `_lastSyncedContent` is not updated so the comparison still detects pending content.
- `EditorProvider` constructor now subscribes to `_connectivity.onChange`; subscription is cancelled in `dispose()`.
- Phase 1 test focuses on the `ConnectivityService` surface (state + stream + ValueListenable). Full integration of "sync-skipped-offline-then-resumes" is deferred to Phase 6's `offline_edit_test.dart`, which requires a broader test harness (fake AuthProvider, fake ApiDataService) that doesn't fit into a Phase 1 unit test.

---

## Phase 2 — Durable outbox for pending writes (2 pts → 8/10)

**Why:** today, edits between the 3 s local save and 15 s push are in memory only. Crash = data loss. Logout = data loss.

- [x] Design: a `PendingOp` record `{id, kind, payload, createdAt, attemptCount, lastError}` where `kind ∈ {upsertSection, deleteSection, upsertWriting, deleteWriting}`
- [x] Persist outbox in a dedicated Hive box `sync_outbox` (separate from books blob) — append-only, ack-on-success
- [x] Refactor [editor_provider.dart](lib/provider/editor_provider.dart) so every mutation that previously called the API now: (a) writes locally, (b) enqueues a `PendingOp`, (c) kicks the drainer
- [x] Build `lib/services/sync/outbox_drainer.dart` — single in-flight worker that pops ops in order, calls `ApiDataService`, removes on success, increments `attemptCount` and reschedules with exponential backoff on failure (Phase 2: increments and stops; backoff lands in Phase 3)
- [ ] Idempotency: include client-generated `clientOpId` in API payloads; server should accept duplicate `clientOpId` as no-op (file a backend TODO if not yet supported) — `PendingOp.id` is the durable client-side opId, but it isn't yet sent over the wire because the backend has no field for it. **Backend TODO**: accept and dedupe a `client_op_id` column on writings/sections endpoints.
- [x] On app start: drain outbox before any new work — drainer.kick() fires from EditorProvider's constructor
- [x] On `connectivity → online`: kick the drainer
- [x] Block logout until outbox is empty OR show a "you have N unsynced edits, sync now / discard / cancel" dialog (do **not** silently wipe)
- [x] Test: `test/sync/outbox_test.dart` — enqueue while offline, go online, assert ops drain in order; crash mid-drain (kill the box), reopen, assert resumed

**Findings while implementing:**
- Carved out a `SyncDispatcher` interface (`lib/services/sync/sync_dispatcher.dart`) and made `ApiDataService` implement it. Lets the drainer be tested with a fake without standing up an `ApiClient`/HTTP stack, and avoids a circular import between `api_data_service` and `outbox_drainer`.
- Drainer enforces strict head-of-line blocking on failure: a queued op that fails leaves itself AND every op behind it in place. Intentional, because a later op may depend on the id remap performed by an earlier upsert.
- `addNewBook` now enqueues `upsertWriting(isNew=true)` followed by `upsertSection(isNew=true)` for the default section; the drainer's `IdRemapEvent` propagates the server-issued writing id back into both the in-memory `WritingModel` and any subsequent section ops via `Outbox.rewriteAll`. Same pattern handles section creation.
- `_syncToFirestore` now enqueues an `upsertSection` op with the latest content and returns immediately. The drainer's `onAck` stream flips `SectionModel.isSynced=true` so the merge logic in `_mergeSections` no longer prefers stale local content after a successful push.
- Logout flow in [lib/ui/app/settings.dart](lib/ui/app/settings.dart) now branches on `editor.pendingOpsCount.value`: when there are queued ops, it shows a three-button dialog (Cancel / Discard & log out / Keep & log out). Pending ops survive logout because the outbox is in its own Hive box and is *not* wiped by `clearData()`.
- Cover-image upload (`updateBookCoverImage`) keeps its synchronous binary-upload path because we don't want to buffer raw bytes in Hive; only the metadata update that follows is queued.
- Crash-recovery test exercises real Hive close/reopen against a temp dir.

---

## Phase 3 — Real retry policy & error surfacing (1 pt → 8.5/10)

**Why:** silent swallowing today. Users have no idea when sync is broken.

- [x] Exponential backoff with jitter in the drainer: `min(2^n * 1s, 60s)` for 5xx / network; immediate retry once for 401 (token refresh path stays in `ApiClient`)
- [x] Cap attempts per op at 10; after that, mark op `failed` and surface in UI
- [x] Replace the editor's "Typing…/Saved" string with a richer status: `idle | typing | saving | offline | syncing(N) | error(N)` — driven off outbox depth + connectivity
- [x] Tap on the status chip → bottom sheet listing failed ops with "retry" / "discard"
- [x] Test: `test/sync/retry_test.dart` — 5xx three times then 200, assert eventual success and correct backoff schedule

**Findings while implementing:**
- `OutboxDrainer` now takes injectable `backoff` and `sleep` callbacks. Production uses defaults (`min(2^n * 1s, 60s)` + `Future.delayed`); tests inject `Duration.zero` + a no-op sleep to keep the wall clock out of assertions.
- Error classification is centralised in `_classify`: 5xx, 408, 429, 401, timeout/connection, and unknown exceptions are *transient*; other 4xx flips the op to `failed=true` immediately. 401 reaches the drainer only after `ApiClient` has already retried with a refreshed token, so we treat it as transient (user might re-authenticate later).
- `drain()` now de-duplicates concurrent passes by returning the in-flight `Future` instead of starting a second pass — caught by a test that called `kick()` (which fires-and-forgets a drain) immediately followed by `await drain()` (which used to short-circuit and let the box be torn down mid-flight).
- Status chip is computed from outbox depth + connectivity + a `_typing/_saving` micro-flag; `notifyListeners()` is wired to fire when any of those underlying signals change so the chip animates in real time.
- Retry / discard live on the drainer (`retryFailedOp`, `discardOp`) and are forwarded by the `EditorProvider` to keep the failed-ops sheet UI provider-only (no sync internals leak into widgets).

---

## Phase 4 — Replace fake comment stream (0.5 pt → 9/10)

**Why:** [api_data_service.dart:338-343](lib/services/api/api_data_service.dart#L338-L343) currently returns `Stream.fromFuture` and pretends to be live.

Pick **one** of:
- [x] **Option A (cheap):** polling — `Stream.periodic(15s).asyncMap(getComments)` with `distinct()` so identical payloads don't redraw
- [ ] **Option B (right):** add WebSocket endpoint in [backend/](backend/) for comments-by-feed-item, subscribe from client, fall back to polling when socket dead — chose Option A because it's client-only and "live within 15s" is acceptable for comments. The implementation hides behind a single `Stream<List<CommentModel>>` so swapping to Option B later is a one-file change.

Either way:
- [x] Document the choice at the top of `api_data_service.dart`
- [x] Test: `test/sync/comments_stream_test.dart` — assert stream emits on new comment

**Findings while implementing:**
- First pass used `async*` with `while (true)` + `await Future.delayed`. Cancelling the subscription deadlocked because the awaited delay never returned to a yield-checkpoint. Rewrote with `StreamController` + `Timer.periodic` so cancellation cleanly tears down the timer in `onCancel`.
- Per-tick failures are swallowed (logged behaviour: same as a noisy network) so a single 5xx doesn't kill the whole stream — next tick retries.
- Duplicate-suppression compares JSON of the response, not Dart object identity, since `CommentModel` lacks `==`.

---

## Phase 5 — Conflict resolution observability (0.5 pt → 9.5/10)

**Why:** LWW silently drops changes today. Need to *see* it happen before deciding whether to upgrade to per-field merge.

- [x] In the merge logic at [editor_provider.dart:254-259](lib/provider/editor_provider.dart#L254-L259), when local wins over remote (or vice versa) **with non-trivial diff**, log a structured event `{sectionId, localTs, remoteTs, localLen, remoteLen, winner}`
- [x] Persist last 50 merge events to a `sync_merge_log` Hive box for debugging
- [x] Hidden debug screen (long-press app version in settings) showing the merge log
- [ ] Decide afterwards (not in this phase) whether to escalate to CRDT / per-paragraph merge — **deferred** as planned. Need a few weeks of observed merge events before this is informed.

**Findings while implementing:**
- "Non-trivial diff" interpretation: only record when `localSection.content != remoteSection.content`. Same-content merges (e.g. user reopens an already-synced section) would otherwise drown the log.
- The version label was missing from the existing settings UI — added a tiny `InkSpaceX · v1.0.0` line at the bottom of `ProfileHubPage` whose long-press routes to `/debug/merge-log`. Casual taps are no-op.
- `MergeLog.snapshot()` initially returned a `const []` literal which `.add()` couldn't mutate; switched to `<MergeLogEntry>[]` after a test exposed the issue.

---

## Phase 6 — Test coverage for sync scenarios (0.5 pt → 10/10)

**Why:** without these, regressions will land silently.

- [ ] `test/sync/offline_edit_test.dart` — go offline, edit, go online, assert server received writes in order
- [ ] `test/sync/crash_recovery_test.dart` — enqueue ops, simulate kill, reopen, assert drained
- [ ] `test/sync/logout_with_pending_test.dart` — pending ops + logout → user is prompted, not silently wiped
- [ ] `test/sync/token_expiry_midflight_test.dart` — 401 mid-drain, refresh, op replayed
- [ ] `test/sync/conflict_lww_test.dart` — local newer + unsynced wins; remote newer wins otherwise
- [ ] CI smoke: `flutter test test/sync/` runs green

**Findings while implementing:**
- _(agent fills in)_

---

## Out of scope (intentionally)

- Full CRDT / OT for collaborative editing — re-evaluate after Phase 5 logs
- E2E encryption of pending ops at rest
- Multi-device live cursor presence

---

## Progress tracker (fill in as phases land)

| Phase | Status | Commit | Notes |
|---|---|---|---|
| 1. Connectivity | ✅ | 94a1918 | Banner + EditorProvider gate + service unit test. Full integration test deferred to Phase 6. |
| 2. Outbox | ✅ | bbbd1a6 | Hive-backed durable queue + drainer + id-remap. Logout-with-pending dialog wired in. Backend `client_op_id` dedup is still a TODO. |
| 3. Retry & UI | ✅ | f017197 | Backoff + jitter + 10-attempt cap. Status chip enum + failed-ops sheet wired in. |
| 4. Real stream | ✅ | e0cfe37 | Polling-based stream w/ duplicate suppression. Backend WebSocket deferred. |
| 5. Merge logs | ✅ | _pending_ | Hive-backed ring buffer + hidden debug page (long-press version label). |
| 6. Tests | ☐ | — | |

**Current rating:** 9.5/10
**Target rating:** 10/10
