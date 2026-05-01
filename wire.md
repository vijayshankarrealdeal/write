# Realtime writing sync — wire-up status

Tracks the work to make a draft edited on one device show up live on another.
Backend SSE plumbing has shipped; the client and a couple of correctness
concerns are still open.

## Done

Shipped in commit `d0b378a` on `origin/main`.

- **Hub channel** — `broadcast_writing(writing_id, payload)` added to
  `_Hub` in [backend/app/realtime.py](backend/app/realtime.py). Channel key:
  `writing:{writing_id}`. Same in-memory pub/sub the notifications and
  comments channels already use.
- **SSE endpoint** — `GET /api/stream/writings/{writing_id}` in
  [backend/app/routers/realtime.py](backend/app/routers/realtime.py).
  Auth via `Authorization: Bearer …` (or `?token=` query fallback).
  Ownership enforced — the requester must own the writing or the stream
  returns 404.
- **Mutation broadcasts** — [backend/app/routers/writings.py](backend/app/routers/writings.py)
  now emits typed events on the writing channel after each commit:
  - `update_writing` → `{type: "writing.updated", writing: {...}}`
  - `delete_writing` → `{type: "writing.deleted", writing_id: "..."}`
  - `create_section` → `{type: "section.created", section: {...}, section_ids: [...]}`
  - `update_section` → `{type: "section.updated", section: {...}}`
  - `delete_section` → `{type: "section.deleted", section_id: "...", section_ids: [...]}`

## Left

### 1. Client-side subscription
- Add `writingChannel(String writingId)` to
  [lib/services/api/api_realtime_service.dart](lib/services/api/api_realtime_service.dart),
  mirroring `commentsChannel` — points at `/api/stream/writings/{id}`.
- In the editor screen
  ([lib/ui/pages/editior_page.dart](lib/ui/pages/editior_page.dart) and the
  writing/section providers), subscribe while the editor is open, tear
  down on dispose. Dispatch `section.*` and `writing.*` events into
  provider state.

### 2. Echo suppression (`op_id`)
- The client that issued a PUT/POST/DELETE will receive the broadcast
  echo of its own write. Without a filter, the editor will redundantly
  re-apply its own edit (in the worst case stomping a newer local key).
- Fix: client generates a uuid `op_id` on every mutating request; backend
  reads it from the request body / header and includes it in the
  `hub.broadcast_writing` payload. Originating client ignores events
  whose `op_id` matches one it sent.
- Backend edits live in
  [backend/app/routers/writings.py](backend/app/routers/writings.py)
  (add `op_id: str | None` to the schemas, thread into payloads).

### 3. Conflict policy with the live editor
- Naive last-writer-wins yanks text from under the cursor when a remote
  patch arrives mid-typing.
- Remote patches must flow through
  [lib/services/sync/](lib/services/sync/) (outbox, merge_log,
  sync_dispatcher) — log conflicts to merge_log so the existing
  "your edit was merged" toast surfaces, instead of overwriting unsaved
  local edits.

### 4. Multi-worker caveat (deferred)
- Hub is in-memory and per-process. If the API ever runs more than one
  Uvicorn worker, only the worker handling the PUT broadcasts; other
  workers' SSE subscribers go silent. Same caveat that already applies
  to notifications/comments — fix is a Redis pub/sub backend swap when
  needed, not now.

## Suggested follow-up agent

After ~3 days, open a PR that does items 1, 2, and 3 above. Do **not**
push directly to `main`. Skip if a PR for this work already exists.
Run `/schedule` to set this up.
