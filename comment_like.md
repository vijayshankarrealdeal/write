# Comment Likes — Implementation Plan

Goal: make the heart on each review tile a real, persisted, cross-device "like" instead of a local-only toggle, with real-time fan-out so two users viewing the same post see counts update live.

The work splits cleanly into two phases. Phase 1 is backend (schema + API + SSE). Phase 2 is the Flutter side (model fields, provider, optimistic UI, SSE handlers).

---

## Phase 1 — Backend

### What's done
Nothing on the backend yet. The current heart icon is purely client-side state in [_CommentTileState](lib/ui/pages/post_detail_page.dart#L5061) — a fresh tile mount resets `_liked = false` and `_likes = 0`.

### What's left for the developer

**1. DB migration** (alembic) — `backend/alembic/versions/<rev>_comment_likes.py`
- New table `comment_likes`:
  - `comment_id UUID FK comments.id ON DELETE CASCADE`
  - `user_id UUID FK users.id ON DELETE CASCADE`
  - `created_at TIMESTAMPTZ DEFAULT NOW()`
  - `PRIMARY KEY (comment_id, user_id)`
  - Index on `(user_id)` for "show me my liked comments" if ever needed.
- Add column `comments.likes_count INTEGER NOT NULL DEFAULT 0` (denormalized counter so list reads stay one query).

**2. Model** — `backend/app/models/comment.py`
- Add `likes_count: Mapped[int]` field on `Comment`.
- Add `CommentLike` SQLAlchemy model mirroring the new table.

**3. API endpoints** — `backend/app/routers/comments.py`
- `POST /api/feed/{item_id}/comments/{comment_id}/like` — insert row, increment `comments.likes_count`, return `{"likes_count": N}`. Idempotent (no-op if row already exists).
- `DELETE /api/feed/{item_id}/comments/{comment_id}/like` — delete row, decrement counter, return `{"likes_count": N}`. Idempotent.
- Use `INSERT ... ON CONFLICT DO NOTHING` (Postgres) so concurrent taps don't fail.

**4. Response shape** — `backend/app/schemas/feed.py`
- `CommentResponse` gains:
  - `likes_count: int`
  - `liked_by_me: bool` (computed per-request from `current_user.id`)
- `_serialize_comment` in [comments.py:19](backend/app/routers/comments.py#L19) needs the same two fields. The existing `list_comments` query should `LEFT JOIN comment_likes ON (comment_id = c.id AND user_id = :me)` and select `(comment_likes.user_id IS NOT NULL) AS liked_by_me`.

**5. SSE broadcast** — same `feed:{item_id}` channel already used for `comment.created` / `like.added`.
- After a successful like/unlike, call:
  ```python
  await hub.broadcast_feed_item(item_id, {
      "type": "comment.like.added",   # or "comment.like.removed"
      "comment_id": str(comment_id),
      "likes_count": comment.likes_count,
      "actor_id": str(user.id),
  })
  ```
- This piggy-backs on the existing channel — no new SSE endpoint needed.

**6. Notification (optional)** — `backend/app/notifications.py`
- New kind `"comment_like"` so the comment's author gets pinged when someone hearts their review. Skip the notification if `actor_id == comment.author_id` (self-like), and debounce/coalesce repeats from the same actor within a window.

**7. Tests** — `backend/tests/test_comment_likes.py`
- Idempotent like/unlike, counter parity, `liked_by_me` flag, SSE payload shape.

---

## Phase 2 — Frontend

### What's done
- `_CommentTile` is now a `StatefulWidget` ([post_detail_page.dart:5045](lib/ui/pages/post_detail_page.dart#L5045)) with the heart UI, count column, and `_toggleLike()` (currently local-only).
- Long-press action sheet with Delete/Report.
- Per-feed-item SSE pipe is already wired and handles `comment.created` / `comment.deleted` / `like.added` / `like.removed` in [_subscribeToFeedItemEvents](lib/ui/pages/post_detail_page.dart#L327). Comment-like events would just be two more cases in the same switch.

### What's left for the developer

**1. Model** — [lib/models/comment_model.dart](lib/models/comment_model.dart)
- Add fields `likesCount` (int) and `likedByMe` (bool).
- Update `fromJson` / `toJson` / `copyWith`.

**2. Data service** — [lib/services/api/api_data_service.dart](lib/services/api/api_data_service.dart)
```dart
Future<int> addCommentLike(String feedItemId, String commentId) async {
  final r = await _client.post('/api/feed/$feedItemId/comments/$commentId/like');
  return (r.data['likes_count'] as num).toInt();
}

Future<int> removeCommentLike(String feedItemId, String commentId) async {
  final r = await _client.delete('/api/feed/$feedItemId/comments/$commentId/like');
  return (r.data['likes_count'] as num).toInt();
}
```

**3. Stream-side reconciliation** — `getCommentsStream` in [api_data_service.dart:777](lib/services/api/api_data_service.dart#L777)
- Add cases in the SSE switch for `comment.like.added` / `comment.like.removed`: find the comment by `comment_id`, swap in a `copyWith(likesCount: payload['likes_count'])`, re-emit the list. Don't touch `likedByMe` from broadcast — the actor's own client already updated it optimistically.

**4. Replace local state in `_CommentTile`** — [post_detail_page.dart:5061](lib/ui/pages/post_detail_page.dart#L5061)
- Drop `_liked` / `_likes` fields. Read from `widget.comment.likedByMe` / `widget.comment.likesCount`.
- `_toggleLike` becomes:
  - Optimistic flip → call `dataService.addCommentLike(...)` / `removeCommentLike(...)` fire-and-forget.
  - On error, revert and show snackbar (mirror the pattern in [_CommentsSheetState._submit](lib/ui/pages/post_detail_page.dart#L4779)).
- Because `CommentModel` is immutable, the optimistic update needs to live somewhere mutable. Easiest path: have `_CommentsSheetState` keep a `Map<String, ({int count, bool liked})> _localLikeOverrides` that the tile reads through; clear an entry when the SSE stream emits a value matching it.

**5. Post-detail SSE handler** — [_subscribeToFeedItemEvents](lib/ui/pages/post_detail_page.dart#L339)
- Add a no-op for `comment.like.added` / `comment.like.removed` (the comment-stream layer already handles per-tile updates), or use them to bump a future "total reactions" badge.

**6. Action-sheet "Like" entry**
- Optional polish: add a top action in the long-press sheet that mirrors the heart tap, so the affordance is also discoverable for users who don't notice the tiny icon.

**7. Tests** — `test/sync/comment_likes_test.dart`
- Optimistic flip + rollback on error, dedup on SSE echo, counter parity.

---

## Rollout order

1. Ship Phase 1 behind a feature check (or just ship — endpoints are additive). Verify counts increment in the DB with curl.
2. Ship Phase 2; the heart goes live the moment the model fields are populated by the API.
3. Backfill `comments.likes_count = 0` in the migration; no historical data to recover.

## Out of scope

- Listing who liked a comment (would need a `GET /comments/{id}/likes` endpoint and a UI surface).
- Reactions other than the heart (would mean a `reaction_type` column on `comment_likes` — design separately if PM asks for it).
- Cross-device sync of likes the *current* user gave on other devices — covered for free by `liked_by_me` being computed server-side per request.
