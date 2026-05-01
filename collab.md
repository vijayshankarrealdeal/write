# Real-time Collaboration — Detailed Design & Phased Plan

> Goal: let multiple users open the same **writing**, edit different **sections** in parallel, optionally co-edit a single section (Phase 4), and see each other's presence — without breaking offline sync or the existing single-user flow.

This document is the **single source of truth** for the collab rollout. Every checkbox in §3 maps to a concrete deliverable. Flip `[ ]` → `[x]` in the **same commit** as the code change. Reviewers reject phase-skipping PRs.

---

## Table of Contents

- [§0 Where We Stand Today](#0-where-we-stand-today)
- [§1 Industry Reference](#1-industry-reference--how-google-docs--ms-word--notion-solve-this)
- [§2 Architecture Overview](#2-architecture-overview)
  - [2.1 Data model additions](#21-data-model-additions)
  - [2.2 Authorization rule](#22-authorization-rule-single-source-of-truth)
  - [2.3 Realtime event taxonomy](#23-realtime-event-taxonomy)
  - [2.4 Lock state machine](#24-lock-state-machine)
  - [2.5 Version & merge model](#25-version--merge-model)
  - [2.6 Offline + collab safety](#26-offline--collab-safety)
  - [2.7 Sequence diagrams](#27-sequence-diagrams)
- [§3 Phased Rollout](#3-phased-rollout)
  - [Phase 1 — Sharing & Read-only](#phase-1--sharing--read-only-collaboration--1-week)
  - [Phase 2 — Co-editing + Locks + Presence](#phase-2--co-editing-with-section-locks--presence--1-week)
  - [Phase 3 — Comments, Suggestions, History](#phase-3--comments-suggestions-and-history--15-weeks)
  - [Phase 4 — Hardening + Optional CRDT](#phase-4--hardening-observability-and-optional-crdt--2-weeks)
- [§4 Process & Working Agreement](#4-process--working-agreement)
- [§5 Error Codes Reference](#5-error-codes-reference)
- [§6 Open Questions](#6-open-questions-resolve-before-the-relevant-phase)
- [§7 File Touchpoints](#7-appendix--file-touchpoints-for-grep)

---

## 0. Where We Stand Today

We already have **most of the realtime plumbing**. What's missing is sharing, conflict handling, and presence.

**Already in place** (do not rebuild):

| Capability | File | Notes |
|---|---|---|
| Pub/sub hub w/ Redis fan-out | [backend/app/realtime.py](backend/app/realtime.py) | Bounded queues, drop-oldest on overflow |
| Per-writing SSE channel | [backend/app/routers/realtime.py:116](backend/app/routers/realtime.py#L116) | `writing:{id}` |
| Echo suppression via `X-Op-Id` | [backend/app/routers/writings.py:29](backend/app/routers/writings.py#L29) | Header header copied into broadcast payload |
| Section + writing broadcast on mutation | [backend/app/routers/writings.py:149,181](backend/app/routers/writings.py#L149) | `section.created`, `section.updated`, etc. |
| Quill Delta document format | [backend/app/ai/delta_utils.py](backend/app/ai/delta_utils.py) | Word-level LCS reprojection — reusable for merges |
| Per-user durable outbox | [lib/services/sync/outbox.dart](lib/services/sync/outbox.dart) | Hive-backed, per-uid box |
| Pending op kinds | [lib/services/sync/pending_op.dart](lib/services/sync/pending_op.dart) | Has `attemptCount`, `nextAttemptAt`, `failed` |
| Auth dep | [backend/app/auth/deps.py:16](backend/app/auth/deps.py#L16) | `get_current_user` — reuse, don't replace |

**The hard parts not yet built:**

1. **Sharing model** — `Writing.user_id` is a single owner ([backend/app/models/writing.py:14](backend/app/models/writing.py#L14)). Every read/write check is `Writing.user_id == user.id`.
2. **Same-section concurrent edits** — last-writer-wins via `PUT /sections/{id}`.
3. **Presence** — no notion of who's viewing or where their cursor is.
4. **Offline-merge safety** — outbox replays writes blindly; once writings are shared, a stale offline edit will clobber a teammate's commit.

---

## 1. Industry Reference — How Google Docs / MS Word / Notion Solve This

| Concern | Google Docs | MS Word (Co-author) | Notion | **Our pick** | Why |
|---|---|---|---|---|---|
| Doc model | OT on text ops | OT on chunks (paragraphs) | Block-CRDT (yjs-like) | **Section-level lock first; CRDT optional Phase 4** | Quill is already CRDT-friendly (we can add yjs later); locks are 1 week, CRDT is 3 weeks |
| Transport | Long-poll → WebSocket | WebSocket via SharePoint | WebSocket | **SSE (have it) → WS only with CRDT** | One direction is enough until char-level merging is in scope |
| Conflict resolution | Server-side OT, char-level | Paragraph-level reconcile | CRDT, char-level | **Section-lock + version guard** | Acceptable for chapter-style writing; rare to need same-paragraph multi-user typing |
| Permission grain | Doc + suggest mode | Doc level | Page + block | **Writing-level + role + suggest** | Section-level perms can come later; not industry-standard for this UX |
| Presence | Cursor + selection + name | Avatar list + cursor | Cursor + avatar | **Same — reuse SSE hub** | Already have the channel |
| Sharing | Email + link | Org + link | Email + link | **Share-link with token** | No SMTP/SES required; backend-first |
| Offline | Drive cache, full reconcile | Limited | Limited | **Outbox + `base_version` guard + 3-way merge** | We already have an outbox; just close the racing-write loophole |

**Why we don't ship CRDT on day one:** Google Docs spent ~3 years on OT. yjs + Postgres snapshotting + Dart binding is a real engineering project. Until users complain about can't-type-in-the-same-paragraph, section locks are 90% of the UX at 10% of the cost.

---

## 2. Architecture Overview

### 2.1 Data model additions

#### 2.1.1 New tables

```sql
-- Membership table. Owner is materialised here too (Phase 1.2 backfill).
CREATE TABLE writing_collaborators (
    writing_id    UUID NOT NULL REFERENCES writings(id) ON DELETE CASCADE,
    user_id       UUID NOT NULL REFERENCES users(id)     ON DELETE CASCADE,
    role          TEXT NOT NULL CHECK (role IN ('owner','editor','commenter','viewer')),
    invited_by    UUID REFERENCES users(id),
    invited_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    accepted_at   TIMESTAMPTZ,
    PRIMARY KEY (writing_id, user_id)
);
CREATE INDEX ix_writing_collab_user ON writing_collaborators (user_id);

-- Share-link tokens. 32-byte url-safe random; never reissue an old token.
CREATE TABLE writing_invites (
    token         TEXT PRIMARY KEY,                  -- secrets.token_urlsafe(32)
    writing_id    UUID NOT NULL REFERENCES writings(id) ON DELETE CASCADE,
    role          TEXT NOT NULL CHECK (role IN ('editor','commenter','viewer')),
    created_by    UUID NOT NULL REFERENCES users(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at    TIMESTAMPTZ,                       -- NULL = never
    max_uses      INTEGER,                           -- NULL = unlimited
    use_count     INTEGER NOT NULL DEFAULT 0,
    revoked_at    TIMESTAMPTZ
);
CREATE INDEX ix_writing_invites_writing ON writing_invites (writing_id);

-- Pessimistic lock. Phase 2.
CREATE TABLE section_locks (
    section_id    UUID PRIMARY KEY REFERENCES sections(id) ON DELETE CASCADE,
    writing_id    UUID NOT NULL,                     -- denormalised for channel routing
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    acquired_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    heartbeat_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_section_locks_heartbeat ON section_locks (heartbeat_at);

-- Version log per section. Phase 2; reused by Phase 3 history.
CREATE TABLE section_versions (
    section_id      UUID NOT NULL REFERENCES sections(id) ON DELETE CASCADE,
    version         BIGINT NOT NULL,
    delta           JSONB NOT NULL,                  -- the committed quill delta
    author_user_id  UUID NOT NULL REFERENCES users(id),
    committed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    op_id           TEXT,                            -- the X-Op-Id that produced this version
    PRIMARY KEY (section_id, version)
);
```

#### 2.1.2 Mutations to existing tables

```sql
-- Add a monotonic version counter. Phase 2.2.
ALTER TABLE sections ADD COLUMN version BIGINT NOT NULL DEFAULT 0;

-- Comments gain anchor metadata. Phase 3.1.
ALTER TABLE comments ADD COLUMN anchor_section_id UUID REFERENCES sections(id) ON DELETE CASCADE;
ALTER TABLE comments ADD COLUMN anchor_index INTEGER;
ALTER TABLE comments ADD COLUMN anchor_length INTEGER;
```

#### 2.1.3 Backfill (Phase 1.2)

```sql
-- Every legacy writing's owner becomes a row in the new collab table.
-- This is what lets the centralised auth check (§2.2) work for old data.
INSERT INTO writing_collaborators (writing_id, user_id, role, invited_at, accepted_at)
SELECT id, user_id, 'owner', now(), now() FROM writings
ON CONFLICT (writing_id, user_id) DO NOTHING;
```

The backfill must run inside the migration's `upgrade()` so it's atomic with the schema change.

### 2.2 Authorization rule (single source of truth)

Replace every ad-hoc `Writing.user_id == user.id` check with a single helper:

```python
# backend/app/auth/collab.py  (new)
ROLE_RANK = {"viewer": 0, "commenter": 1, "editor": 2, "owner": 3}

async def get_writing_for(
    user: User,
    writing_id: UUID,
    *,
    min_role: str,                   # 'viewer' | 'commenter' | 'editor' | 'owner'
    db: AsyncSession,
) -> tuple[Writing, str]:            # returns (writing, caller_role)
    """Fetch writing iff user has at least `min_role`. 404 on miss
    (don't leak existence), 403 on insufficient role."""
    row = (await db.execute(
        select(Writing, WritingCollaborator.role)
        .join(WritingCollaborator,
              WritingCollaborator.writing_id == Writing.id)
        .where(Writing.id == writing_id,
               WritingCollaborator.user_id == user.id)
    )).first()
    if row is None:
        raise HTTPException(404, "Writing not found")
    writing, role = row
    if ROLE_RANK[role] < ROLE_RANK[min_role]:
        raise HTTPException(403, f"Requires role {min_role}")
    return writing, role
```

**Mandate:** after Phase 1, `grep -rn "user_id == user.id" backend/app/routers/` must return **zero hits in writings/comments/highlights/bookmarks/realtime routers**. Anyone adding a new ad-hoc check fails review.

| Endpoint | min_role |
|---|---|
| `GET    /writings/`                          | (lists what the user has access to — no per-row check needed; query joins on collab table) |
| `GET    /writings/{id}` and `/sections`      | `viewer` |
| `POST   /writings/{id}/comments`             | `commenter` |
| `POST/PUT/DELETE /writings/{id}/sections/*`  | `editor` |
| `POST   /writings/{id}/invites`              | `owner` |
| `DELETE /writings/{id}` (delete writing)     | `owner` |
| SSE `/realtime/writings/{id}/stream`         | `viewer` |

### 2.3 Realtime event taxonomy

Channel: `writing:{writing_id}` (existing, multiplexed). Every event is a JSON object with `type`, `op_id` (echo-suppression — present even if null), and a type-specific body.

| `type` | Origin | Body | Client behaviour |
|---|---|---|---|
| `writing.updated` (existing) | server | `{writing}` | Apply diff |
| `writing.deleted` (existing) | server | `{writing_id}` | Pop from library |
| `section.created` (existing) | server | `{section, section_ids}` | Insert in editor |
| `section.updated` (existing) | server | `{section, version}` | Apply iff `version > local.version` |
| `section.deleted` (existing) | server | `{section_id, section_ids}` | Remove + redirect if open |
| `section.locked` | server (on lock acquire) | `{section_id, user_id, name, until}` | Disable editor, show banner |
| `section.unlocked` | server (release / TTL) | `{section_id}` | Re-enable editor |
| `presence.snapshot` | server (on connect) | `{users: [{user_id,name,avatar,color,section_id?,cursor?}]}` | Initialise avatar stack |
| `presence.join` | server | `{user_id, name, avatar, color}` | Add chip |
| `presence.leave` | server | `{user_id}` | Remove chip + cursor |
| `presence.cursor` | client→server→broadcast | `{user_id, section_id, index, length}` | Render remote caret |
| `collaborator.added` | server | `{user_id, role, name}` | Refresh share sheet |
| `collaborator.removed` | server | `{user_id}` | Remove from share sheet; if it's *me*, kick to library |
| `collaborator.role_changed` | server | `{user_id, role}` | Update badge; re-evaluate my UI if it's me |
| `comment.added` (Phase 3) | server | `{comment}` | Insert in thread sidebar |
| `comment.resolved` | server | `{comment_id}` | Move to resolved tab |
| `suggestion.added` | server | `{suggestion}` | Inline candidate marker |
| `suggestion.decided` | server | `{suggestion_id, status}` | Animate accept/reject |

**Wire format (SSE frame):**

```
id: 1714568800123
data: {"type":"section.locked","op_id":null,"section_id":"...","user_id":"...","name":"Aria","until":"2026-05-01T12:00:30Z"}

```

The `id` field uses millisecond timestamp so clients can resume with `Last-Event-ID` (already supported by [backend/app/realtime.py:222](backend/app/realtime.py#L222)).

### 2.4 Lock state machine

```
              ┌────────┐ acquire 200            ┌──────────────┐
   open  ───▶ │ TRYING │ ────────────────────▶ │  HOLDING     │ ◀───┐
              └────────┘                        │  (heartbeat) │     │ heartbeat 200
                  │ acquire 409                 └──────┬───────┘     │
                  ▼                                    │             │
            ┌──────────────┐                           │ release / blur / dispose
            │ READ_ONLY    │                           ▼
            │ (mirror)     │                     ┌──────────┐
            └──────┬───────┘                     │ RELEASED │
                   │                              └──────────┘
                   │ section.unlocked event           ▲
                   ▼                                  │
              re-attempt acquire ───────── on PUT 409 STALE_VERSION → MERGING
```

Server side, `POST /lock` is a single SQL statement:

```sql
INSERT INTO section_locks (section_id, writing_id, user_id)
VALUES (:sid, :wid, :uid)
ON CONFLICT (section_id) DO UPDATE
SET user_id      = EXCLUDED.user_id,
    acquired_at  = now(),
    heartbeat_at = now()
WHERE section_locks.heartbeat_at < now() - INTERVAL '30 seconds'
   OR section_locks.user_id = EXCLUDED.user_id     -- same-user re-acquire is idempotent
RETURNING user_id, acquired_at;
```

If the `RETURNING` row's `user_id` matches the caller, the lock is theirs. Otherwise the lock is held by someone else — return 409 with `{holder: {user_id, name}}`.

A single asyncio sweeper deletes stale locks and broadcasts `section.unlocked`:

```python
# backend/app/collab/lock_sweeper.py  (new)
async def sweep_locks_forever():
    while True:
        try:
            stale = await db.execute(
                delete(SectionLock)
                .where(SectionLock.heartbeat_at < func.now() - text("INTERVAL '30 seconds'"))
                .returning(SectionLock.section_id, SectionLock.writing_id)
            )
            for section_id, writing_id in stale:
                await hub.broadcast_writing(writing_id, {
                    "type": "section.unlocked",
                    "op_id": None,
                    "section_id": str(section_id),
                })
        except Exception:
            log.exception("lock sweeper iteration failed")
        await asyncio.sleep(10)
```

Started in the FastAPI lifespan alongside `hub.start()`. **One sweeper across all workers** — gate with a Redis `SETNX collab:lock_sweeper` lease so two workers don't double-broadcast.

### 2.5 Version & merge model

Each section has a monotonic `version` (BIGINT). Every successful `PUT` increments it and writes a row to `section_versions`.

`PUT /writings/{w}/sections/{s}` request body gains:

```json
{
  "title": "...",
  "content": { "ops": [...] },
  "base_version": 42
}
```

Server logic (replaces current [backend/app/routers/writings.py:177](backend/app/routers/writings.py#L177)):

```python
async def update_section(...):
    writing, role = await get_writing_for(user, writing_id, min_role="editor", db=db)

    section = await db.get(Section, section_id, with_for_update=True)   # row-lock
    if section is None or section.writing_id != writing_id:
        raise HTTPException(404, "Section not found")

    # Lock check (Phase 2.5). Skip if section has no lock at all.
    lock = await db.get(SectionLock, section_id)
    if lock is not None and lock.user_id != user.id:
        raise HTTPException(409, {"code":"LOCK_REQUIRED","holder":{"user_id":str(lock.user_id)}})

    # Version guard.
    if data.base_version is not None and data.base_version < section.version:
        raise HTTPException(409, {
            "code": "STALE_VERSION",
            "current_version": section.version,
            "current_content": section.content,
        })

    # Apply.
    for field, value in data.model_dump(exclude_unset=True, exclude={"base_version"}).items():
        setattr(section, field, value)
    section.version += 1
    db.add(SectionVersion(
        section_id=section.id, version=section.version,
        delta=section.content, author_user_id=user.id, op_id=op_id,
    ))
    await db.commit()
    await db.refresh(section)
    await hub.broadcast_writing(writing_id, {
        "type": "section.updated",
        "op_id": op_id,
        "section": SectionResponse.model_validate(section).model_dump(mode="json"),
        "version": section.version,
    })
    return section
```

#### 2.5.1 Merge algorithm (3-way, for offline catch-up)

When a client comes back online and gets `STALE_VERSION`, it has three deltas: `base` (what they branched from), `mine` (their offline edits), `theirs` (server's current). Merge:

1. **Auto-merge** if the paragraphs touched are disjoint. Use [backend/app/ai/delta_utils.py:47](backend/app/ai/delta_utils.py#L47)'s `extract_paragraphs` to split `mine` and `theirs`. If the paragraph index sets don't intersect, concatenate.
2. **Auto-merge** for format-only changes on the same paragraph. Word-LCS (already implemented) reprojects: same word survives → keep the union of formats; conflicting attribute → prefer `theirs`.
3. **Manual** otherwise: open the merge dialog (Phase 4.6 expands the existing [merge_log.dart](lib/services/sync/merge_log.dart)). Show 3-way diff; user picks paragraph-by-paragraph.

The merge runs **client-side** so the server stays simple. Result is a fresh `PUT` with `base_version = current_version_observed`.

### 2.6 Offline + collab safety

Today: `PendingOp.upsertSection` carries the new content. After Phase 2 sharing exists, this can clobber a teammate's commit.

Fix in [pending_op.dart](lib/services/sync/pending_op.dart):

```dart
// before
PendingOp(kind: PendingOpKind.upsertSection, payload: {'sectionId': ..., 'content': ...})

// after
PendingOp(kind: PendingOpKind.upsertSection, payload: {
  'sectionId': ...,
  'content': ...,
  'baseVersion': 42,   // captured when the user started editing
})
```

In [outbox_drainer.dart](lib/services/sync/outbox_drainer.dart):

```dart
final res = await api.putSection(..., baseVersion: op.payload['baseVersion']);
if (res.statusCode == 409 && res.body['code'] == 'STALE_VERSION') {
  await mergeLog.recordConflict(op, serverVersion: res.body['current_version'], serverContent: res.body['current_content']);
  // Do NOT mark failed-and-give-up. Mark `needsMerge` so the editor surfaces it next time the user opens the section.
  op.failed = true;          // exits drain queue
  op.lastError = 'merge_required';
  await outbox.update(op);
  return;
}
```

The editor, on opening a section, checks `mergeLog` for a pending merge for that section before rendering normal mode. If one exists → open merge dialog.

### 2.7 Sequence diagrams

#### 2.7.1 Invite + accept (Phase 1)

```
Owner                Backend                Invitee (already signed in)
  │   POST /writings/{w}/invites              │
  │ ─────────────────────────────────▶        │
  │   201 {token, url, role}                  │
  │ ◀─────────────────────────────────        │
  │   share url out-of-band (chat/email)──────▶
  │                                           │
  │                                  POST /invites/{token}/accept
  │                                  ◀─────────────────────────────
  │                                  200 {writing_id}
  │                                  ─────────────────────────────▶
  │             collaborator.added event over writing:{w}          │
  │ ◀────────── broadcast ──────────────────────────────────────── │
```

#### 2.7.2 Co-edit with locks (Phase 2)

```
User A (editor)               Backend                       User B (editor)
  │ POST /sections/{s}/lock                                        │
  │ ──────────────▶                                                │
  │ 200 {lock_id}                                                  │
  │ ◀──────────────                                                │
  │            broadcast section.locked{s, A}                      │
  │ ◀────────────────────────────────────────────────────────────▶ │
  │                                                                │ B opens same section, sees locked banner
  │                                                                │
  │ PUT /sections/{s} {content, base_version=42}                   │
  │ ──────────────▶                                                │
  │ 200 {version=43}                                               │
  │ ◀──────────────                                                │
  │            broadcast section.updated{version=43}               │
  │ ◀────────────────────────────────────────────────────────────▶ │
  │                                                                │ B's editor mirrors the delta read-only
  │ ... 30s of inactivity, A's tab closed ...                      │
  │                                                                │
  │ (lock sweeper detects heartbeat_at expired)                    │
  │            broadcast section.unlocked{s}                       │
  │ ◀────────────────────────────────────────────────────────────▶ │
  │                                                                │ B's editor: "claim edit" button enabled
```

#### 2.7.3 Offline conflict (Phase 2 / 4)

```
Time T: A and B both have section v=10
T+1m: A goes offline, edits para 3 locally → outbox queued with base_version=10
T+5m: B (online) edits para 5 → server v=11, broadcast
T+30m: A reconnects → drainer PUTs with base_version=10
       Server: 409 STALE_VERSION{current_version=11, current_content=...}
       Client: mergeLog records, op marked needsMerge
T+30m+ε: A's editor opens, detects pending merge → dialog
       Auto-merge: paragraphs disjoint → emit fresh PUT base_version=11
       Server: 200 v=12, broadcast section.updated
```

---

## 3. Phased Rollout

> **Legend** — `[ ]` pending · `[x]` done · `[~]` in progress · `[!]` blocked  
> **Definition of Done** — every checkbox in a phase is `[x]` and the "Done when" criterion at the bottom of the phase is verified by manual QA + green pytest run.

---

### Phase 1 — Sharing & Read-only Collaboration  *(1 week)*

> Outcome: a user can invite others by share-link; invitees can open the writing in **read-only** and see live updates. No co-editing yet.

#### 1.1 Migration: collab tables  `[ ]`

- File: `backend/alembic/versions/2026MMDD_collab_phase1.py`
- `upgrade()` creates `writing_collaborators` and `writing_invites` exactly as in §2.1.1.
- `upgrade()` runs the backfill in §2.1.3.
- `downgrade()` drops both tables (writes are blocked during downgrade — document this in the migration docstring).
- **Test:** `alembic upgrade head` then `alembic downgrade -1` round-trips on a fresh DB.

#### 1.2 ORM models  `[ ]`

- File: `backend/app/models/collab.py` (new)
- Classes: `WritingCollaborator`, `WritingInvite` mapping the §2.1.1 columns. Composite PK on `WritingCollaborator`. Use `relationship(back_populates=...)` from `Writing`.
- Add `collaborators: Mapped[list["WritingCollaborator"]]` to [backend/app/models/writing.py](backend/app/models/writing.py).
- Register both in `backend/app/models/__init__.py`.

#### 1.3 Centralised auth helper  `[ ]`

- File: `backend/app/auth/collab.py` (new) — code in §2.2.
- Replace every `_get_user_writing` call site:
  - [backend/app/routers/writings.py:221](backend/app/routers/writings.py#L221) — delete `_get_user_writing`, inline `get_writing_for(user, writing_id, min_role="editor", db=db)` (or `viewer` for GETs).
  - [backend/app/routers/realtime.py:110](backend/app/routers/realtime.py#L110) — `min_role="viewer"`.
  - [backend/app/routers/comments.py](backend/app/routers/comments.py), `highlights.py`, `bookmarks.py` — same treatment for any route scoped by writing.
- Acceptance grep: `grep -rn "user_id == user.id" backend/app/routers/` → empty for collab-touched routers.

#### 1.4 Collab router  `[ ]`

- File: `backend/app/routers/collab.py` (new). Mounted under `/api/collab`.

| Method | Path | Min role | Body / Query | Returns |
|---|---|---|---|---|
| POST | `/writings/{wid}/invites` | owner | `{role, expires_in_days?, max_uses?}` | 201 `{token, url, role, expires_at, max_uses}` |
| GET  | `/writings/{wid}/invites` | owner | — | 200 `[invite, ...]` (active only by default; `?include_revoked=true` shows all) |
| DELETE | `/writings/{wid}/invites/{token}` | owner | — | 204 (sets `revoked_at`) |
| POST | `/invites/{token}/accept` | authed | — | 200 `{writing_id, role}` or 410 (expired/revoked/exhausted) |
| GET  | `/invites/{token}` | authed | — | 200 `{writing_title, owner_name, role}` (preview before accept) |
| GET  | `/writings/{wid}/collaborators` | viewer | — | 200 `[{user_id,name,avatar,role,invited_at,accepted_at}]` |
| PATCH | `/writings/{wid}/collaborators/{uid}` | owner | `{role}` | 200 `{role}`; broadcasts `collaborator.role_changed` |
| DELETE | `/writings/{wid}/collaborators/{uid}` | owner OR `uid==me` (leave) | — | 204; broadcasts `collaborator.removed` |

- Token gen: `secrets.token_urlsafe(32)`. URL is `https://app.example.com/invite/{token}` — host comes from `settings.app_base_url`.
- Acceptance must be **idempotent**: calling `accept` twice with the same token returns the existing collaborator row (200), and only increments `use_count` once per `(token, user_id)`.

#### 1.5 List writings includes shared  `[ ]`

- Modify [backend/app/routers/writings.py:36](backend/app/routers/writings.py#L36):

```python
result = await db.execute(
    select(Writing, WritingCollaborator.role)
    .join(WritingCollaborator, WritingCollaborator.writing_id == Writing.id)
    .where(WritingCollaborator.user_id == user.id)
    .order_by(Writing.updated_at.desc())
)
return [WritingResponse.from_row(w, role=r) for w, r in result.all()]
```

- `WritingResponse` gains `my_role: str` and `collaborator_count: int`.

#### 1.6 Schema updates  `[ ]`

- [backend/app/schemas/writing.py](backend/app/schemas/writing.py) — add `my_role`, `collaborator_count`.
- New `backend/app/schemas/collab.py` with `InviteCreate`, `InviteResponse`, `CollaboratorResponse`, `RolePatch`.

#### 1.7 Frontend share sheet  `[ ]`

- File: `lib/ui/pages/editor_page_entry/share/share_sheet.dart` (new)
- Sections:
  - **People** — list collaborators with role chip; owner can change role / remove.
  - **Links** — list active invite links; owner can copy URL, revoke, create new (role + expiry selector).
  - **Pending invites** — invites with no `accepted_at` (Phase 1 doesn't have email so this is mostly empty; leave the list for Phase 3 when notifications hook in).
- Calls API service in `lib/services/api/collab_api.dart` (new).

#### 1.8 Deep-link handler  `[ ]`

- App scheme: `inkspacex://invite/{token}` and HTTPS `https://<app_base_url>/invite/{token}`.
- Handler at [lib/services/](lib/services/) (or wherever existing deep-link routing lives — grep `app_links` package usage):
  1. If not signed in → push to login, store pending token in secure storage.
  2. After auth → `GET /api/collab/invites/{token}` to preview.
  3. Show preview sheet: "Aria invited you to *Writing Title* as Editor. Accept?"
  4. On confirm → `POST /accept` → navigate to writing.

#### 1.9 Read-only mode in editor  `[ ]`

- [lib/ui/pages/editor_page_entry/editor_page_entry.dart](lib/ui/pages/editor_page_entry/editor_page_entry.dart) — gate all write paths on `writing.myRole`:
  - `viewer` / `commenter` → toolbar hidden, AI bottom sheet hides write actions, Quill controller `readOnly: true`.
  - `editor` / `owner` → full UI.
- App-bar badge: small role pill ("Editor", "Viewer", "Owner").

#### 1.10 Tests  `[ ]`

- `backend/tests/test_collab_phase1.py`:
  - Permission matrix: 4 roles × 6 endpoints (read writing, list sections, edit section, comment, invite, delete writing). Each cell asserts the expected status code (200/204/403/404).
  - Invite lifecycle: create → accept → re-accept (idempotent) → revoke → accept (gone).
  - Share-link with `max_uses=1` exhausts after one accept.
  - Backfill correctness: assert every existing writing has exactly one `owner` row.
- Manual QA: open shared writing in two browsers, edit on owner's side, verify viewer's editor reflects changes via SSE.

**Done when:** Owner shares a writing → invitee sees it in their library with role badge → invitee opens it read-only → invitee receives owner's edits live. No regression in single-user flow.

---

### Phase 2 — Co-editing with Section Locks + Presence  *(1 week)*

> Outcome: editors can write in **different** sections at the same time. Same section ⇒ first-acquirer locks, others see live read-only with a presence chip.

#### 2.1 Migration: locks + versions  `[ ]`

- File: `backend/alembic/versions/2026MMDD_collab_phase2.py`
- `upgrade()`: `section_locks`, `section_versions` tables (§2.1.1) + `sections.version BIGINT NOT NULL DEFAULT 0`.
- Backfill: insert one `section_versions(section_id, version=0, delta=current_content, author=writing.user_id)` per existing section so v=0 is reproducible.
- **Test:** round-trip; verify `version` defaults stick and existing sections survive.

#### 2.2 ORM updates  `[ ]`

- Add `version` to [backend/app/models/section.py](backend/app/models/section.py).
- New models in `backend/app/models/collab.py`: `SectionLock`, `SectionVersion`.

#### 2.3 Lock endpoints  `[ ]`

| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/writings/{w}/sections/{s}/lock` | — | 200 `{user_id, acquired_at, expires_at}` or 409 `{holder:{user_id,name}, expires_at}` |
| PUT  | `/writings/{w}/sections/{s}/lock/heartbeat` | — | 200 `{expires_at}` or 409 (lost it) |
| DELETE | `/writings/{w}/sections/{s}/lock` | — | 204 (always; deleting a non-existent lock is fine) |

- Acquire SQL is the conditional `INSERT ... ON CONFLICT` from §2.4.
- Heartbeat is `UPDATE section_locks SET heartbeat_at=now() WHERE section_id=:s AND user_id=:u RETURNING heartbeat_at`. If no row updated → 409.
- Release is `DELETE WHERE section_id=:s AND user_id=:u`. After delete, broadcast `section.unlocked`.
- Acquire/release/sweeper all broadcast `section.locked` / `section.unlocked` over `writing:{w}`.

#### 2.4 Lock sweeper  `[ ]`

- File: `backend/app/collab/lock_sweeper.py` (new) — code in §2.4.
- Wire into `backend/app/main.py` lifespan after `hub.start()`. Cancel on shutdown.
- Singleton across workers via Redis lease:

```python
async def acquire_lease():
    return await redis.set("collab:lock_sweeper", worker_id, nx=True, ex=15)
# heartbeat the lease every 5s; if lost, stop sweeping until reacquired
```

In single-worker dev (no Redis), skip the lease and just run.

#### 2.5 Update section guard  `[ ]`

- Replace [backend/app/routers/writings.py:161](backend/app/routers/writings.py#L161) with the §2.5 version-guarded handler.
- Error envelope for 409s:

```json
{ "detail": { "code": "STALE_VERSION", "current_version": 43, "current_content": {...} } }
{ "detail": { "code": "LOCK_REQUIRED", "holder": { "user_id": "...", "name": "Aria" } } }
```

- `SectionUpdate` schema gains `base_version: int | None = None`.

#### 2.6 Presence  `[ ]`

- File: `backend/app/collab/presence.py` (new). Two layers:
  - **Connection presence** — when an SSE client connects, increment `(writing_id, user_id)` ref-count; when disconnects, decrement. On 0→1 broadcast `presence.join`. On 1→0 broadcast `presence.leave`. Send `presence.snapshot` to the joining client first.
  - **Cursor presence** — `POST /api/collab/writings/{w}/presence/cursor {section_id, index, length}` → broadcast `presence.cursor`. Throttled at 10/s per user (§4.1).
- Storage: Redis hash `presence:{writing_id} → {user_id: json}`, TTL 60s, refreshed on each cursor post.
- User color: deterministic hash of `user_id` → 8 distinct hues (Tailwind 500 palette). Stable across sessions so collaborators recognise each other.

#### 2.7 Frontend: editor lock + cursors  `[ ]`

Edits in [lib/ui/pages/editor_page_entry/](lib/ui/pages/editor_page_entry/):

1. On section open:
   - `POST /lock`. On 200 → `HOLDING` state, start 15s heartbeat.
   - On 409 → `READ_ONLY` state, render `LockedByOtherBanner(holder.name)` + "Request to edit" button.
2. Heartbeat timer: every 15s `PUT /lock/heartbeat`. On 409 → revert to `READ_ONLY`.
3. On dispose / app background / blur: `DELETE /lock`. Use `WidgetsBindingObserver.didChangeAppLifecycleState` for background.
4. Subscribe to `section.locked` / `section.unlocked` for the open writing — when remote unlocks the section I'm in, surface "Section is now editable — claim?" snackbar.
5. Render remote cursors: extend Quill controller to accept `RemoteCursor(userId, color, index, length)` decorations. Caret + 12px name pill above. Fade after 5s of no movement.
6. Avatar stack in app bar from `presence.snapshot` + `presence.join` / `.leave`.

#### 2.8 Outbox version-awareness  `[ ]`

- [pending_op.dart](lib/services/sync/pending_op.dart): `upsertSection` payload includes `baseVersion`.
- [outbox_drainer.dart](lib/services/sync/outbox_drainer.dart): handle 409 STALE_VERSION as in §2.6 — record in mergeLog, mark op `failed` with `lastError='merge_required'`, do not retry.
- New per-section flag `hasPendingMerge` exposed via a `ValueListenable` so the editor can show a "Resolve merge" banner when opening that section.

#### 2.9 UX polish: request-to-edit  `[ ]`

- "Request to edit" button on lock banner sends a notification (existing `notifications` system) to the lock holder: "Aria wants to edit this section". Holder taps → releases lock.
- No force takeover in Phase 2. Holders can ignore; the requester just waits or works elsewhere.

#### 2.10 Load test + verification  `[ ]`

- Script: `backend/scripts/load_collab.py` (new). Spins up 5 fake users, opens 1 writing with 5 sections, hammers cursor + section update for 5 minutes.
- Pass criteria:
  - Lock acquire success > 95% when sections are disjoint.
  - Broadcast p95 latency < 200ms.
  - No stuck locks after sweeper runs.
  - SSE connections stable (no leak; `select count(*) from pg_stat_activity` flat).

**Done when:** two users editing different sections see each other's edits live with no conflicts; same-section attempt shows lock banner; killing a tab releases the lock within 30s; no stale locks after a 5-minute load test.

---

### Phase 3 — Comments, Suggestions, and History  *(1.5 weeks)*

> Outcome: collaborators can comment in-line, propose suggested edits (Google-Docs-style), and browse a per-section version history.

#### 3.1 Comment anchoring migration  `[ ]`

- File: `backend/alembic/versions/2026MMDD_collab_phase3.py`
- `ALTER TABLE comments ADD COLUMN anchor_section_id UUID REFERENCES sections(id) ON DELETE CASCADE;`
- `ALTER TABLE comments ADD COLUMN anchor_index INTEGER;`
- `ALTER TABLE comments ADD COLUMN anchor_length INTEGER;`
- New table:

```sql
CREATE TABLE section_suggestions (
    id              UUID PRIMARY KEY,
    section_id      UUID NOT NULL REFERENCES sections(id) ON DELETE CASCADE,
    base_version    BIGINT NOT NULL,
    delta           JSONB NOT NULL,
    author_user_id  UUID NOT NULL REFERENCES users(id),
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','accepted','rejected','superseded')),
    rationale       TEXT,
    decided_by      UUID REFERENCES users(id),
    decided_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_suggestions_section_status ON section_suggestions (section_id, status);
```

#### 3.2 Inline comments  `[ ]`

- Existing comments router gains `anchor_section_id`, `anchor_index`, `anchor_length` in create/response schemas.
- Endpoints:
  - `POST /writings/{w}/sections/{s}/comments` — body `{body, anchor_index, anchor_length, parent_id?}` → broadcast `comment.added`.
  - `POST /comments/{id}/resolve` → broadcast `comment.resolved`.
- Anchor maintenance: when a section is updated, all anchors on that section must be transformed through the delta.
  - New helper: `transform_index_through_delta(old_index, old_to_new_delta) -> new_index` in [delta_utils.py](backend/app/ai/delta_utils.py).
  - Run on every `section.updated` server-side; emit `comment.updated` if the anchor moved or `comment.detached` if the anchored span was deleted.

#### 3.3 Comments UI  `[ ]`

- Right-rail thread view (collapsible). Each thread anchored to a paragraph; clicking scrolls + highlights.
- Selection-anchored "Comment" button in the toolbar. Posts comment with the current selection range.
- Resolve / reopen, reply (parent_id), @-mention picker (uses `/api/collab/writings/{w}/collaborators` for the autocomplete list).

#### 3.4 Suggestions  `[ ]`

- `Commenter` role can submit a suggestion: `POST /writings/{w}/sections/{s}/suggestions {delta, base_version, rationale?}`.
- `Editor` / `Owner` reviews:
  - `POST /suggestions/{id}/accept` — applies the delta on top of current section content (via merge if `base_version < section.version`); transitions other pending suggestions on the same span to `superseded`. Broadcasts `suggestion.decided{status:accepted}` + `section.updated`.
  - `POST /suggestions/{id}/reject` — broadcasts `suggestion.decided{status:rejected}`.
- UI: suggestions render as colored insertion/strike highlights inline (Google-Docs style). Sidebar lists pending suggestions; accept/reject buttons there too.

#### 3.5 Version history  `[ ]`

- `GET /writings/{w}/sections/{s}/versions?limit=50&before=...` returns a paginated list of `section_versions` with author + timestamp (no delta payload by default — too heavy).
- `GET /writings/{w}/sections/{s}/versions/{v}` returns the full delta for a specific version.
- UI: "Version history" panel — scrubber over versions, preview pane, "Restore" button writes a new version with `op_id=restore-from-{v}`. Restore is **never destructive**; the old versions remain.

#### 3.6 Notifications  `[ ]`

- Hook into existing `backend/app/notifications.py`:
  - New comment + I'm in the thread or @-mentioned.
  - New suggestion on a section I authored or last-edited.
  - Suggestion accepted/rejected on a suggestion I authored.
  - Role changed for me on a writing.
- Reuse existing FCM dispatcher.

#### 3.7 Tests  `[ ]`

- `test_comment_anchor_transform.py`:
  - Insert before anchor → anchor moves.
  - Delete spanning anchor → comment goes `detached`.
  - Format-only change → anchor stable.
- `test_suggestion_lifecycle.py`: pending → accepted on top of newer base → merges cleanly when disjoint, falls back to "needs author review" when conflicting.
- `test_version_restore.py`: restore version 5 onto current → version 12 contains v5's delta and `op_id` reflects the restore.

**Done when:** non-owners can comment + suggest; owners can review and accept; every accepted suggestion shows up in version history; comment anchors survive subsequent edits.

---

### Phase 4 — Hardening, Observability, and Optional CRDT  *(2 weeks)*

> Outcome: collab is production-grade. Decision point on whether to invest in true simultaneous-typing-in-same-section (CRDT).

#### 4.1 Rate limits  `[ ]`

- Reuse [backend/app/middleware.py](backend/app/middleware.py). Per-user, per-route limits using a token-bucket on Redis:
  - `presence.cursor`: 10/s
  - `update_section`: 4/s
  - `lock heartbeat`: 1/10s (clients heartbeat at 1/15s — well below the limit)
  - `comment.create`: 1/s
  - `invite.create`: 10/min
- Excess returns 429 `{retry_after_ms}`. Client respects.

#### 4.2 Auditing  `[ ]`

- Append-only `collab_audit_log(id, writing_id, actor_id, action, target_id, payload, created_at)`.
- Actions: `invite.create`, `invite.revoke`, `collaborator.add`, `collaborator.role_change`, `collaborator.remove`, `suggestion.accept`, `suggestion.reject`, `version.restore`.
- Surfaced in admin dashboard ([backend/app/routers/admin.py](backend/app/routers/admin.py)) — owner of writing can view `GET /writings/{w}/audit`.

#### 4.3 Quotas  `[ ]`

- Max 50 collaborators per writing (configurable in `settings`).
- Max 10 active (non-revoked, non-expired) invite links per writing.
- Enforced at create-time. 422 with `{code:"QUOTA_EXCEEDED", limit, current}`.

#### 4.4 Metrics  `[ ]`

- Prometheus (or whatever the existing analytics dispatcher uses):
  - `collab_sse_connections{writing_id_hash}` gauge.
  - `collab_lock_acquire{result=success|conflict}` counter.
  - `collab_stale_version` counter.
  - `collab_presence_messages` counter.
  - `collab_merge{auto|manual}` counter.
- Dashboard panels grouped under "Collaboration".

#### 4.5 Security audit  `[ ]`

- Invite tokens: `secrets.token_urlsafe(32)` (256-bit). Stored as-is; tokens are bearer credentials so we accept the tradeoff.
- Per-IP rate limit on `POST /invites/{token}/accept`: 30/hour to prevent token brute-force (token space is huge but defense-in-depth).
- Default invite expiry: 14 days. Admin can override in settings.
- Revocation: immediate (server checks `revoked_at` on every `accept`). Already-accepted users stay accepted; revocation only blocks new accepts.
- Audit pass: read every collab endpoint with the OWASP top-10 lens. Document findings in `backend/SECURITY.md`.

#### 4.6 3-way merge UI  `[ ]`

- Replace the simple merge dialog from Phase 2 with a 3-pane view: **Base** | **Mine** | **Theirs** | **Result**.
- Per-paragraph picker: keep mine / keep theirs / both / edit. Auto-pick disjoint paragraphs.
- "Apply" issues a fresh `PUT` with `base_version = current_observed`.
- Unit-tested with synthetic delta triplets — easy to regression-test.

#### 4.7 Decision: do we need CRDT?  `[ ]`

- **Trigger:** ship 4.1–4.6, run for 2 weeks, then evaluate.
- **Go-CRDT criteria (any one):**
  - Lock-conflict rate > 5% across writings with ≥2 collaborators.
  - User feedback explicitly requests "type at the same time".
  - Avg session is single-section with multiple editors waiting.
- **Skip-CRDT criteria:** lock-conflict < 1%, no user complaints. Mark Phase 4.7 done with "skipped, locks suffice"; close 4.8 / 4.9 as won't-do.

#### 4.8 *(if CRDT)* yjs spike  `[ ]`

- New service: `y-websocket` server next to FastAPI (or as a uvicorn route on `/ws/writing/{id}`).
- Protocol: yjs sync protocol. Persist snapshots to Postgres `section_versions` every N updates and on graceful disconnect.
- Dart binding: `yjs_dart` (verify maintenance status; otherwise wrap a tiny JS bridge via `flutter_inappwebview` or write the OT primitives in pure Dart for the Quill subset we need).
- Coexistence: when CRDT is active for a section, locks are bypassed — yjs handles concurrent edits.

#### 4.9 *(if CRDT)* Feature flag rollout  `[ ]`

- Flag: `writings.collab_mode in ('locks', 'crdt')`. Default `locks`. Owner can opt into `crdt` per writing.
- Internal dogfood → 10% rollout → GA.
- Locks remain in code as the fallback when flag is off or yjs server is down.

#### 4.10 Documentation  `[ ]`

- Update this `collab.md` §0 to reflect what shipped.
- User-facing share/role docs in `lib/assets/` + in-app help.
- Internal runbook: how to investigate stuck locks, replay missed broadcasts, recover a corrupted suggestion thread.

**Done when:** all metrics on dashboard; abuse vectors documented + mitigated; CRDT decision is **made and recorded** (either "skipped, locks suffice" or "shipped behind flag, X% rollout").

---

## 4. Process & Working Agreement

1. **One phase at a time.** Do not start Phase N+1 until **all** items in Phase N are checked. PRs that reach across phases are split or rejected.
2. **Migrations are sequential and reversible.** Every Alembic revision must have a working `downgrade()`. Test the round-trip.
3. **Backend-first** (per CLAUDE preference): every feature is a REST/SSE endpoint and pytest coverage **before** any Flutter code is written. The Dart side stays a dumb consumer.
4. **Echo suppression is sacred.** Every new mutation route forwards `X-Op-Id` into its broadcast payload. Tests assert this — see existing pattern in [backend/app/routers/writings.py:29](backend/app/routers/writings.py#L29).
5. **Authorisation is centralised.** Only `get_writing_for(...)` decides access. Direct `user_id == ...` checks are review-blockers after Phase 1.
6. **Track progress here.** When a checkbox flips, update this file in the **same commit** as the code change. The diff in this file is part of the PR description.
7. **Tests gate phase completion.** Phase done = green pytest + manual QA per the "Done when" line.
8. **Open questions** (§6) get resolved before the relevant phase, not during. If a question is still open when the phase starts, the phase is `[!]` blocked.

---

## 5. Error Codes Reference

| HTTP | `code` | Meaning | Client action |
|---|---|---|---|
| 401 | (default) | Auth missing/expired | Re-login |
| 403 | (default) | Role insufficient | Show "you don't have permission" toast |
| 404 | (default) | Writing/section not found OR no access | Treat as not-existing (don't leak existence) |
| 409 | `LOCK_REQUIRED` | Editing a section locked by someone else | Render locked banner, switch to read-only |
| 409 | `STALE_VERSION` | `base_version` < server version | Open merge dialog or auto-merge |
| 409 | `LOCK_LOST` | Heartbeat / release on a lock the user no longer holds | Revert to read-only; re-attempt acquire |
| 410 | `INVITE_EXPIRED` | Token past `expires_at` | "This invite has expired" |
| 410 | `INVITE_REVOKED` | Token's `revoked_at` set | "This invite was revoked" |
| 410 | `INVITE_EXHAUSTED` | `use_count >= max_uses` | "This invite has reached its limit" |
| 422 | `QUOTA_EXCEEDED` | Hit a Phase 4.3 quota | Surface limit + current count |
| 429 | (default) | Rate-limited | Honour `retry_after_ms`, queue locally |

All error bodies use FastAPI's `{"detail": <body>}` envelope. The `code` field lives inside `detail` when the error is structured.

---

## 6. Open Questions (resolve before the relevant phase)

- [ ] **P1** Do invite links require login, or grant guest sessions? *(Recommendation: require login — every event ties to a real `user_id`; simpler auth.)*
- [ ] **P2** Lock TTL = 30s, heartbeat = 15s — acceptable on cellular? *(Test on slow networks; consider 20s/40s if drops are common.)*
- [ ] **P2** When a takeover happens after a crash, do we toast the original holder when they come back? *(Lean: yes, with "your edits were saved as draft v_X" link.)*
- [ ] **P2** Mobile background behaviour — release lock immediately or wait for OS-killed process to time out? *(Recommendation: release on `paused` lifecycle so a backgrounded user doesn't hold locks for 30s.)*
- [ ] **P3** Suggestion storage: full deltas or op-paths? *(Recommendation: full deltas — simpler; we already merge them via word-LCS.)*
- [ ] **P3** Comment anchor on detach: keep with `detached=true` flag, or hard-delete? *(Recommendation: keep — users may want to see "this thread was about deleted text".)*
- [ ] **P4** WebSocket vs SSE for CRDT? *(SSE is one-way; CRDT needs duplex. Plan to add `/ws/writing/{id}` only for CRDT-mode writings.)*
- [ ] **P4** Per-writing CRDT flag vs per-workspace? *(Recommendation: per-writing — gives owners control without an org concept.)*

---

## 7. Appendix — File Touchpoints (for grep)

| Concern | File |
|---|---|
| Auth dependency | [backend/app/auth/deps.py:16](backend/app/auth/deps.py#L16) |
| **New** centralised collab auth | `backend/app/auth/collab.py` (Phase 1.3) |
| Writing/section CRUD | [backend/app/routers/writings.py](backend/app/routers/writings.py) |
| **New** collab router | `backend/app/routers/collab.py` (Phase 1.4) |
| **New** lock sweeper | `backend/app/collab/lock_sweeper.py` (Phase 2.4) |
| **New** presence | `backend/app/collab/presence.py` (Phase 2.6) |
| SSE entrypoint | [backend/app/routers/realtime.py](backend/app/routers/realtime.py) |
| Pub/sub hub | [backend/app/realtime.py](backend/app/realtime.py) |
| Schemas | [backend/app/schemas/writing.py](backend/app/schemas/writing.py), `backend/app/schemas/collab.py` (new) |
| Models | [backend/app/models/writing.py](backend/app/models/writing.py), [backend/app/models/section.py](backend/app/models/section.py), `backend/app/models/collab.py` (new) |
| Delta merging | [backend/app/ai/delta_utils.py](backend/app/ai/delta_utils.py) |
| Offline outbox | [lib/services/sync/outbox.dart](lib/services/sync/outbox.dart), [lib/services/sync/pending_op.dart](lib/services/sync/pending_op.dart), [lib/services/sync/outbox_drainer.dart](lib/services/sync/outbox_drainer.dart) |
| Merge log | [lib/services/sync/merge_log.dart](lib/services/sync/merge_log.dart) |
| Editor page | [lib/ui/pages/editor_page_entry/](lib/ui/pages/editor_page_entry/) |
| Section model (Dart) | [lib/models/section_model.dart](lib/models/section_model.dart) |
| Section version model (Dart) | [lib/models/section_version_model.dart](lib/models/section_version_model.dart) |
| Notifications | [backend/app/notifications.py](backend/app/notifications.py) |
| Middleware (rate limits) | [backend/app/middleware.py](backend/app/middleware.py) |
| Admin dashboard | [backend/app/routers/admin.py](backend/app/routers/admin.py) |

---

*Last updated: 2026-05-01 — Phase 1.1 pending. Update this header on every phase boundary.*
