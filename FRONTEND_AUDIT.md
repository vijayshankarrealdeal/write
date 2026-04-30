# Frontend Heavy-Lifting Audit

**Principle:** all read/write heavy lifting (compression, encoding, search, ranking, business logic, third-party API calls, secrets) lives on the FastAPI backend. The Flutter app only:
- calls REST endpoints we own
- listens to SSE/streams we own
- renders, manages local UI state, handles device APIs (camera/photos), and caches
- runs offline-first plumbing (Hive, outbox, `.inkx` package decryption)

Everything else is a violation.

Date: 2026-04-30

---

## Summary

| | Count |
|---|---|
| Violations found | **1** (8 call sites, same root cause) |
| Violations fixed in this audit | **1** |
| Borderline (left as-is, justified below) | 3 |
| Legitimate frontend work | 7 categories |

---

## Violations — fixed

### 1. `image_picker` was resizing + JPEG re-encoding photos on the device before upload

**Status:** ✅ Fixed in this audit.

**Root cause:** every photo-pick call site passed `maxWidth` and `imageQuality` to `ImagePicker.pickImage(...)`. On Android/iOS those parameters trigger native bitmap resize + JPEG re-encode in the platform plugin; on web, canvas resize. That's literal compression on the frontend — exactly what the principle forbids.

The backend already does the right thing in [`backend/app/routers/upload.py`](backend/app/routers/upload.py) → `process_image()` ([backend/app/image_pipeline.py](backend/app/image_pipeline.py)): decodes via Pillow, generates `small`/`medium`/`large`/`original` variants in WebP, computes blurhash + dominant color, and stores everything in MinIO. `MAX_SIZE = 15MB` and `MAX_IMAGE_PIXELS = 50M` already protect against absurd uploads.

The frontend resize was therefore both **redundant** (server resizes anyway) and **harmful** (a lossy pre-resize before the server's high-quality LANCZOS resize ⇒ worse final variants).

**Affected files (8 call sites):**

| # | File | Old | Fix |
|---|---|---|---|
| 1 | [lib/ui/app/settings.dart](lib/ui/app/settings.dart#L375) | profile photo: `maxWidth: 512, imageQuality: 70` | params removed |
| 2 | [lib/ui/editor/canvas_editor.dart](lib/ui/editor/canvas_editor.dart#L242) `_pickAndAddImage` | canvas insert: `maxWidth: 1200, imageQuality: 75` | params removed |
| 3 | [lib/ui/editor/canvas_editor.dart](lib/ui/editor/canvas_editor.dart#L1107) `_pickImageForElement` | canvas placeholder fill: `maxWidth: 1200, imageQuality: 75` | params removed |
| 4 | [lib/ui/editor/canvas_editor.dart](lib/ui/editor/canvas_editor.dart#L1846) inline background picker | canvas BG: `maxWidth: 1600, imageQuality: 80` | params removed |
| 5 | [lib/ui/pages/create_bookshelf_page.dart](lib/ui/pages/create_bookshelf_page.dart#L46) `_pickCover` | bookshelf cover: `maxWidth: 1600, imageQuality: 80` | params removed |
| 6 | [lib/ui/pages/new_book_addition.dart](lib/ui/pages/new_book_addition.dart#L58) `_pickImage` | book cover: `maxWidth: 1200, imageQuality: 70` | params removed |
| 7 | [lib/ui/pages/publish_page.dart](lib/ui/pages/publish_page.dart#L116) `_pickCoverImage` | publish cover: `maxWidth: 1200, imageQuality: 70` | params removed |
| 8 | [lib/ui/pages/editior_page.dart](lib/ui/pages/editior_page.dart#L280) inline editor image | inline editor image: `maxWidth: 1200, imageQuality: 70` | params removed |

**Result:** the device hands raw bytes to the backend. The backend produces every variant from the highest-quality source. Quality goes up, frontend work goes down.

**Tradeoff acknowledged:** mobile uploads now ship the full-size original (a 12MP phone JPEG ≈ 4–6 MB). Backend already caps at 15 MB and 50 Mpx. If mobile-cellular upload time ever becomes a measurable problem, the right fix is **HTTP-side concerns** (resumable uploads, presigned PUT to MinIO, stricter MIME) — *not* re-introducing client-side compression. Compression stays server-side.

---

## Borderline — left as-is, justified

### B1. Editor word-diff for AI suggestion preview

[lib/ui/pages/editior_page.dart](lib/ui/pages/editior_page.dart) lines ~3000–3043 run a Myers/LCS word diff to render coloured added/removed spans when the user previews an AI rewrite. It's O(m·n) on tokenised words of one section's selected text, runs only on preview tap, and is purely visual feedback for an edit the user is about to accept or reject. Round-tripping it to the backend would add latency for no semantic gain.

**Verdict:** UI rendering aid, not data transformation. Stays on frontend.

### B2. Feed grouping by author + cover

[lib/provider/feed_provider.dart](lib/provider/feed_provider.dart) `groupedItems` walks the feed list once and merges items that share author + cover into a single grouped UI tile. O(n) on a screenful of cards. Server-side grouping is feasible (`/api/feed?group=true`) but would change a public API for what is currently a layout decision.

**Verdict:** Cheap, layout-driven. Move only if grouping logic ever becomes ranked/personalised.

### B3. Editor LWW merge + ghost-book remap on sync

[lib/provider/editor_provider.dart](lib/provider/editor_provider.dart) `_mergeBooks` / `mergeSectionsLww` reconciles local Hive state with the server response on sync. This is intrinsic to offline-first: the device must decide what local state has been superseded by the server before pushing/pulling. Server-side LWW wouldn't help — the client still holds the older state.

**Verdict:** Sync plumbing, required for offline-first. Stays on frontend.

---

## Legitimate frontend work — confirmed clean

These all touched the audit's keyword filters but are correct frontend responsibilities:

1. **`.inkx` offline package decryption** — [lib/services/offline/inkx_codec.dart](lib/services/offline/inkx_codec.dart) uses AES-GCM, HKDF-SHA256, Ed25519 verify (`package:cryptography`). Required because the device may be offline. Public verify key is bundled at build via `--dart-define=INKX_LICENSE_PUBLIC_KEY`. No secrets shipped.
2. **Sync outbox + drainer** — [lib/services/sync/outbox.dart](lib/services/sync/outbox.dart), [outbox_drainer.dart](lib/services/sync/outbox_drainer.dart), [merge_log.dart](lib/services/sync/merge_log.dart) queue idempotent REST ops while offline and replay them. Stores op metadata, not document bodies.
3. **Image cache** — [lib/services/image_cache_manager.dart](lib/services/image_cache_manager.dart) configures `flutter_cache_manager` (30d stale, 400 obj cap). Caching only, no encoding.
4. **Gemini service** — [lib/services/gemini_service.dart](lib/services/gemini_service.dart) calls our backend (`POST /api/ai/text-edit`, `/api/ai/canvas`). No third-party API direct, no API keys.
5. **Auth client** — [lib/services/api/api_auth_service.dart](lib/services/api/api_auth_service.dart) holds zero credentials post-Google-OAuth-rework. JWTs only. Native uses `url_launcher` + polling against [`/api/auth/google/session/{id}`](backend/app/routers/auth.py).
6. **`String.fromEnvironment`** — only two uses, both fine: `API_BASE_URL` (deployment URL, not a secret) in [lib/services/api/api_client.dart](lib/services/api/api_client.dart); `INKX_LICENSE_PUBLIC_KEY` (public key, not a secret) in [lib/provider/offline_provider.dart](lib/provider/offline_provider.dart).
7. **No compression / no third-party APIs / no parsers** — grep for `gzip`, `zlib`, `archive`, `BrotliCodec`, `package:image`, `flutter_image_compress`, `https://api.openai.com`, `https://generativelanguage.googleapis.com`, PDF/EPUB/CSV parsing → all empty.

---

## Going forward (rules of thumb)

- New feature wants to compute, transform, sort, score, or aggregate non-trivial data → write a backend endpoint, not a Dart loop.
- New feature wants to talk to a third-party (Stripe, OpenAI, Gemini, S3, …) → backend proxies, frontend calls our REST.
- New feature wants to compress, encode, or hash → backend, unless the data must stay on-device (offline `.inkx` only).
- New `pickImage` / `pickFiles` / `pickVideo` calls → no `maxWidth`/`imageQuality`/`compress*` params. Backend handles it.
- New SDK package in `pubspec.yaml` that is not pure UI/device → ask first.
