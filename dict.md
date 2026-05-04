# Personal Dictionary → Global Dictionary

End-to-end pipeline for harvesting "Add to dictionary" taps, curating
them with an AI-assisted admin merge, and pushing the result back to
every device as a delta-synced cache.

## Architecture (one-line)

```
device  ──submit──▶  raw queue  ──admin merge (LLM filter)──▶  global dict  ──snapshot delta + SSE──▶  device cache
```

The raw queue is **never** consulted by the spell-checker — only
admin-curated words make it to the global dictionary. The snapshot
fetch sends a single integer (`since=<version>`) and gets a delta back;
no user prose ever crosses that path.

## What's done

### Backend (FastAPI + Postgres)

- **Models** ([backend/app/models/dictionary.py](backend/app/models/dictionary.py))
  - `dictionary_submissions` — raw per-user word additions (PK: id; UQ on `(user_id, word, language)`)
  - `dictionary_words` — curated global dictionary (PK: `(word, language)`; carries `added_in_version` for delta queries)
  - `dictionary_removals` — tombstones so removed words leave client caches
  - `dictionary_meta` — singleton row with the current `version`
- **Migration** ([backend/alembic/versions/20260504_01_dictionary.py](backend/alembic/versions/20260504_01_dictionary.py)) — idempotent (`IF NOT EXISTS`), seeds the meta row at `version=0`
- **User endpoints** ([backend/app/routers/dictionary.py](backend/app/routers/dictionary.py))
  - `POST /api/dictionary/submit` — body `{word, language}`, dedup'd per user
  - `GET /api/dictionary/snapshot?since=<int>&language=en` — returns `{version, added: [...], removed: [...]}` (empty arrays when up to date)
- **SSE channel** ([backend/app/realtime.py](backend/app/realtime.py), [backend/app/routers/realtime.py](backend/app/routers/realtime.py))
  - `GET /api/stream/dictionary` — payload `{type: "dictionary.updated", version: N}`; carries no word strings
- **Admin endpoints** ([backend/app/routers/admin.py](backend/app/routers/admin.py))
  - `GET /api/admin/dictionary/stats` — pending / approved / rejected / global_words / version
  - `GET /api/admin/dictionary/submissions?status=pending` — paginated raw queue with submitter counts
  - `GET /api/admin/dictionary/words` — paginated global dict browser with search
  - `DELETE /api/admin/dictionary/words/{word}` — pull a word, write tombstone, broadcast SSE
  - `POST /api/admin/dictionary/merge` — runs LLM classifier on every pending word, accepts/rejects in one transaction, bumps version once, broadcasts SSE, hot-reloads the in-memory spell-check engine
- **AI merge pipeline** ([backend/app/ai/dictionary_merge.py](backend/app/ai/dictionary_merge.py))
  - System prompt enumerates accept/reject criteria (proper nouns ✓, slurs ✗, typos ✗, PII patterns ✗)
  - Batched at 200 words per completion; partial failures fail-closed (reject)
  - Strict JSON schema; missing entries default to reject
- **Spell engine integration** ([backend/app/spellcheck.py](backend/app/spellcheck.py))
  - `add_words` / `remove_words` for hot-reload
  - `warm_with_global_dict` folds the merged dict into pyspellchecker on lifespan startup so a redeploy doesn't re-flag previously-accepted words

### Admin dashboard (React + Vite)

- **Route** [admin/src/pages/Dictionary.jsx](admin/src/pages/Dictionary.jsx) wired into [admin/src/App.jsx](admin/src/App.jsx) and the sidebar in [admin/src/components/DashboardLayout.jsx](admin/src/components/DashboardLayout.jsx) — "Dictionary" entry, BookText icon
- **Stats cards** — Pending / Approved / Rejected / Global words / Version
- **"Merge N pending"** button — confirms, calls `POST /api/admin/dictionary/merge`, shows result banner with accepted/rejected counts
- **Submissions tab** — Pending/Approved/Rejected filter, per-row submitter count
- **Global dictionary tab** — search, paginated browse, per-row Trash icon to remove

### Flutter client

- **DictionaryService** ([lib/services/dictionary_service.dart](lib/services/dictionary_service.dart))
  - `init()` — loads cached words + version from Hive
  - `refresh()` — `GET /api/dictionary/snapshot?since=<cached>`, applies delta, persists to Hive (single-flight via `_refreshFuture`)
  - `submitWord(word)` — `POST /api/dictionary/submit`, fire-and-forget
  - `attachRealtime(realtime)` — subscribes to the `dictionary` SSE channel; every ping triggers a `refresh()`
- **Hive cache** ([lib/services/storage_service.dart](lib/services/storage_service.dart#L361)) — keys `global_dictionary_words_v1`, `global_dictionary_version_v1` (shared across users on the device — the dictionary is global, not user-scoped)
- **Wire-up in main.dart** ([lib/main.dart](lib/main.dart#L346))
  - `DictionaryService` provider — calls `init()` then `refresh()` at app boot
  - `SpellCheckProvider` now takes `DictionaryService` so `addToDictionary` also calls `submitWord`
  - `_DictionaryAutoRefresh` proxy provider re-binds the SSE listener every time `AuthProvider` rotates its realtime service (login / logout / re-auth) and forces a fresh `refresh()`
- **SSE channel** ([lib/services/api/api_realtime_service.dart](lib/services/api/api_realtime_service.dart) — added `dictionaryChannel()`)

### Privacy + Terms

- **Privacy Policy** ([privacy_policy.html](privacy_policy.html)) — added §3.1 entry for personal-dictionary submissions and §8 retention rule (12-month audit window then anonymisation)
- **Terms of Service** ([terms_of_service.html](terms_of_service.html)) — added §3.5 covering the licence grant for accepted words, the no-redistribution clause for the merged dict, and the user representation that submissions don't contain credentials

## What's left / known gaps

- **Bundled base dictionary** was deliberately not shipped. The device starts with an empty cache (version 0) and the first `/api/dictionary/snapshot` returns the entire merged dict in one delta. Spell-checking itself stays server-side via `/api/spellcheck/check`, which still uses pyspellchecker's bundled English list (~120k words) plus the merged dict folded in via `warm_with_global_dict`.
- **No on-device spell-check engine yet.** The synced dict is currently used only as a forward-looking cache. To go fully offline we'd need to bundle a Hunspell-compatible engine in the app and have it consume the same Hive-cached word set.
- **SSE channel auth.** `GET /api/stream/dictionary` requires a valid user token but every authenticated client gets the same global event. That's intentional (the version number is non-sensitive), but if we ever broadcast diffs over SSE instead of just the bump, scope it.
- **Caddy/nginx tweak.** None needed — the new `/api/stream/dictionary` SSE endpoint inherits the existing realtime config.

## Recently closed gaps

- **Rate-limit on `/submit`** — daily per-user cap, configurable via `DICTIONARY_SUBMIT_DAILY_CAP` (default 50). Returns HTTP 429 once exhausted. ([backend/app/routers/dictionary.py](backend/app/routers/dictionary.py), [backend/app/config.py](backend/app/config.py))
- **Audit log on admin merge** — new `admin_audit` table, populated on every dictionary merge and global word removal; surfaced via `GET /api/admin/audit`. ([backend/app/models/admin_audit.py](backend/app/models/admin_audit.py), [backend/alembic/versions/20260504_02_audit_and_retention.py](backend/alembic/versions/20260504_02_audit_and_retention.py))
- **Per-user retention sweep** — `dictionary_submissions.user_id` is now nullable; daily background task NULLs rows older than `DICTIONARY_SUBMISSION_RETENTION_DAYS` (default 365). One-shot CLI at `python -m backend.scripts.dictionary_retention`. ([backend/app/dictionary_retention.py](backend/app/dictionary_retention.py))
- **Multi-language client wiring** — `DictionaryService` derives its language from the platform locale (override available); cache keys, snapshot fetches, and submissions are all scoped per language. ([lib/services/dictionary_service.dart](lib/services/dictionary_service.dart), [lib/services/storage_service.dart](lib/services/storage_service.dart#L361)). Server-side checkers for non-`en` languages are still required to make this useful end-to-end.
- **`pubspec.yaml` version bump** — bumped to `1.0.2+6` for the dictionary delivery.

## Operational runbook

1. **Run the migration** on a real Postgres: `alembic upgrade head` (the dev path's `create_all` already picks it up).
2. **Build the admin SPA** so the new Dictionary page is served: from `admin/`, `npm run build` → output goes to `backend/admin-dist`. The FastAPI lifespan picks that up automatically.
3. **Open the admin dashboard** at `/admin`, log in, click "Dictionary" in the sidebar.
4. **Wait for users to add words** — submissions land in the Pending tab.
5. **Click "Merge N pending"** — the AI pipeline runs; accepted words ship to every connected device via SSE within seconds.
