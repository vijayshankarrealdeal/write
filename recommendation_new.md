# Recommendation v2 — Parallel Build Plan

**Goal:** ship the 4 highest-ROI upgrades to the "For You" pipeline + 1 publish-side polish, ported from Twitter's open-source algorithm. Each upgrade is built as an isolated module by a separate agent so 5 Opus 4.7 (1M) instances can work simultaneously without touching the same files. A final sequential integration step wires the modules into [recommendation.py](backend/app/ai/recommendation.py).

**Why these 5:** see `Why these 5?` at the bottom. Short answer: 20% of the work, 80% of the lift.

---

## Status board

Tick a box only when the step is **merged into the track's branch and the track's tests pass**. Integration ticks belong to Track 6 only.

| Track | Owner | Branch | Status | Lines (est.) |
|---|---|---|---|---|
| 1. Follow-graph signal | Agent A | `rec/follow-signal` | ✅ Done | 141 + 244 tests |
| 2. Already-shown dedup | Agent B | `rec/seen-filter` | ✅ Done | 111 + 292 tests + migration |
| 3. Completion & deep-scroll signals | Agent C | `rec/completion-signal` | ✅ Done | 144 + 345 tests |
| 4. Exponential author diversity | Agent D | `rec/author-diversity` | ✅ Done | 101 + 194 tests |
| 5. Writing → FeedItem metadata auto-sync | Agent E | `rec/metadata-sync` | ✅ Done | 63 + 399 tests |
| 6. Integration into recommendation.py | Coordinator (Vijay) | `main` | ✅ Done | ~110 |
| 0. (bonus) Baseline measurement script | Agent F | `rec/baseline` | ✅ Done | 246 |

---

## Ground rules (READ BEFORE STARTING)

**File ownership — strict.** Each track lists `Owns` (write) and `Reads` (read-only). An agent **must not** write to anything outside its `Owns` list. The integration step (Track 6) is the only place where `recommendation.py` is edited.

**Why isolation matters.** Tracks 1, 3, 4 would all naturally edit `recommendation.py`. We dodge that by having each track build a **self-contained module exposing a fixed function signature** (defined below). Track 6 imports them and wires them in. Result: no merge conflicts between parallel tracks.

**Worktree per agent.**
```bash
# From /Users/vijayshankar/Desktop/write
git worktree add .claude/worktrees/rec-follow-signal     -b rec/follow-signal     main
git worktree add .claude/worktrees/rec-seen-filter       -b rec/seen-filter       main
git worktree add .claude/worktrees/rec-completion-signal -b rec/completion-signal main
git worktree add .claude/worktrees/rec-author-diversity  -b rec/author-diversity  main
git worktree add .claude/worktrees/rec-metadata-sync     -b rec/metadata-sync     main
```
Each agent `cd`s into its worktree and never leaves. Track 6 is run on `main` after all 5 are merged.

**Testing convention.** Each track must add tests in `backend/tests/ai/test_<module>.py` and pass them with:
```bash
cd backend && pytest tests/ai/test_<module>.py -v
```

**Commit style.** Conventional: `feat(rec): <track name>`. Body explains the signal and cites this plan file.

**Reminder — user runs the app from `main`.** Worktree branches are invisible at runtime; the user will only see effects after Track 6 lands on `main`.

---

## Track 1 — Follow-Graph Signal

**Hypothesis:** The strongest declared interest signal in the database (Follow) currently has zero ranking weight. Adding it will lift CTR on followed-author items dramatically.

**Owns (write):**
- `backend/app/ai/signals/__init__.py` (create empty + `from .follow import follow_boost, followed_author_candidates`)
- `backend/app/ai/signals/follow.py` (new)
- `backend/tests/ai/test_follow_signal.py` (new)

**Reads (no writes):**
- [follow.py (model)](backend/app/models/follow.py)
- [user.py (model)](backend/app/models/user.py)
- [feed_item.py (model)](backend/app/models/feed_item.py)
- [recommendation.py](backend/app/ai/recommendation.py) — for context only

**Public interface (Track 6 will call exactly these):**
```python
# backend/app/ai/signals/follow.py

async def get_followed_author_ids(
    db: AsyncSession, user_id: UUID
) -> set[UUID]:
    """Return set of author user ids the given user follows (status='approved')."""

def follow_boost(item_author_id: UUID, followed_ids: set[UUID]) -> float:
    """Return +4.0 if author is followed, else 0.0. Pure function."""

async def followed_author_candidates(
    db: AsyncSession,
    user_id: UUID,
    followed_ids: set[UUID],
    limit: int = 100,
    days: int = 30,
) -> list[UUID]:
    """Return recent public, non-draft feed_item ids whose author_id is in followed_ids.
    Newest first, capped to `limit`. Excludes the user's own items."""
```

**Steps**
- [x] Read [follow.py (model)](backend/app/models/follow.py) and confirm `status` column values; only `'approved'` follows count.
- [x] Create `backend/app/ai/signals/__init__.py` re-exporting the three functions above.
- [x] Implement `get_followed_author_ids` (single SELECT, returns a set).
- [x] Implement `follow_boost` (pure function, no DB).
- [x] Implement `followed_author_candidates` — query [FeedItem](backend/app/models/feed_item.py) where `author_id = ANY(:followed_ids) AND is_draft = false`, apply `public_feed_clause`, order by `created_at DESC`, limit. Exclude `author_id = user_id`.
- [x] Tests: empty follows → empty set / 0.0 boost / [] candidates; one follow → contains expected ids; private items by followed author → excluded unless requesting user is approved follower.
- [x] `pytest backend/tests/ai/test_follow_signal.py -v` passes.
- [x] Commit on `rec/follow-signal`. Update status box above to ✅.

**Done when:** all checkboxes ticked, tests green, branch pushed (do not merge — coordinator handles).

---

## Track 2 — Already-Shown Dedup

**Hypothesis:** Eliminates the "I keep seeing the same book" complaint. Uses the impression log we already write but never read.

**Owns (write):**
- `backend/app/ai/signals/seen.py` (new)
- `backend/tests/ai/test_seen_filter.py` (new)
- `backend/alembic/versions/<timestamp>_recommendation_event_index.py` (new migration)

**Reads (no writes):**
- [analytics.py](backend/app/models/analytics.py) — `RecommendationEvent` schema
- [recommendation.py](backend/app/ai/recommendation.py) — for context only
- Existing migrations under `backend/alembic/versions/` (newest one defines `down_revision` for the new migration)

**Public interface:**
```python
# backend/app/ai/signals/seen.py

async def get_recently_seen_ids(
    db: AsyncSession,
    user_id: UUID,
    days: int = 10,
) -> set[UUID]:
    """Return feed_item_ids the user has had impressions for in the last `days` days.
    Excludes clicked items (they were engaged with; safe to re-show eventually)."""

def filter_seen(
    candidates: list[UUID],
    seen: set[UUID],
    keep_top_n: int = 0,
) -> list[UUID]:
    """Drop seen ids from candidates. If keep_top_n > 0, keep the first N candidates
    even if seen (for evergreen popular items). Pure function, preserves order."""
```

**Steps**
- [x] Read [analytics.py](backend/app/models/analytics.py) → confirm `RecommendationEvent` has `user_id`, `event_type`, `feed_item_id`, `created_at`.
- [x] Find newest migration revision in `backend/alembic/versions/` — note its `revision = "..."` for `down_revision`.
- [x] Write migration adding `CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_rec_events_user_type_time ON recommendation_events (user_id, event_type, created_at DESC)` — *use raw SQL via `op.execute` so CONCURRENTLY works*; do not wrap in transaction (`transactional_ddl = False` if needed).
- [x] Implement `get_recently_seen_ids` — `SELECT DISTINCT feed_item_id FROM recommendation_events WHERE user_id = :uid AND event_type = 'impression' AND created_at > now() - interval ':days days'`.
- [x] Implement `filter_seen` (pure function).
- [x] Tests: no impressions → empty set; impressions present → returned; `filter_seen` removes seen items and preserves order; `keep_top_n` honors evergreen ids.
- [x] `pytest backend/tests/ai/test_seen_filter.py -v` passes.
- [x] Commit on `rec/seen-filter`. Update status box.

**Done when:** all checkboxes ticked, migration applied cleanly in a scratch DB (`alembic upgrade head`), tests green.

---

## Track 3 — Completion & Deep-Scroll Signals

**Hypothesis:** `ReadingProgress.completed=True` is the strongest "this was good" signal in the database and is currently unused by the profile builder. Adding it (and deep-scroll proxy `scroll_position > 0.7`) will produce truer profiles than likes alone.

**Owns (write):**
- `backend/app/ai/signals/completion.py` (new)
- `backend/tests/ai/test_completion_signal.py` (new)

**Reads (no writes):**
- [reading_progress.py](backend/app/models/reading_progress.py)
- [feed_item.py](backend/app/models/feed_item.py)
- [recommendation.py](backend/app/ai/recommendation.py) — for the existing `_aggregate_profile` weight scale (context only)

**Public interface:**
```python
# backend/app/ai/signals/completion.py

@dataclass(frozen=True)
class CompletionSignals:
    completed_item_ids: list[UUID]      # ReadingProgress.completed = True
    deep_scroll_item_ids: list[UUID]    # scroll_position > 0.7, not completed
    abandoned_item_ids: list[UUID]      # scroll_position < 0.25

async def get_completion_signals(
    db: AsyncSession, user_id: UUID
) -> CompletionSignals:
    """Pull the user's ReadingProgress rows and bucket by progress depth."""

# Weight contributions, additive on top of existing aggregator:
COMPLETION_WEIGHT = 3.0     # > favorite (3.0); ties on purpose — completing
                            # is on par with favoriting in strength
DEEP_SCROLL_WEIGHT = 1.5    # < complete, > like

def apply_completion_to_profile(
    profile_weights: dict[str, float],  # mutated in place: genre/tag → weight
    signals: CompletionSignals,
    item_metadata: dict[UUID, dict],    # item_id → {"genres": [...], "tags": [...], "writing_types": [...]}
) -> None:
    """For each completed/deep-scroll item, add weight contributions to the
    user's genre/tag/type buckets. Abandon penalty is already handled by
    existing aggregator — do not double-apply."""
```

**Steps**
- [x] Read [reading_progress.py](backend/app/models/reading_progress.py) — confirm columns `user_id`, `feed_item_id`, `scroll_position`, `completed`.
- [x] Implement `get_completion_signals` (single SELECT + Python bucketing).
- [x] Implement `apply_completion_to_profile` — pure function, mutates dict.
- [x] Tests: empty signals → no mutation; one completion → expected weight delta on the item's genres/tags/types; deep-scroll item not double-counted if also completed; missing metadata for an item → silently skip.
- [x] `pytest backend/tests/ai/test_completion_signal.py -v` passes.
- [x] Commit on `rec/completion-signal`. Update status box.

**Done when:** all checkboxes ticked, tests green.

---

## Track 4 — Exponential Author Diversity

**Hypothesis:** The current hard cap of 2 items/author is binary. Twitter's exponential decay (`multiplier = (1 - floor) × decay^position + floor`) smoothly demotes repeat appearances without ever silencing a great author.

**Owns (write):**
- `backend/app/ai/signals/diversity.py` (new)
- `backend/tests/ai/test_diversity.py` (new)

**Reads (no writes):**
- [recommendation.py](backend/app/ai/recommendation.py) — for the current per-author cap implementation (context only)
- [feed_item.py](backend/app/models/feed_item.py) — for `author_id` field

**Public interface:**
```python
# backend/app/ai/signals/diversity.py

@dataclass(frozen=True)
class DiversityConfig:
    decay: float = 0.6   # multiplier base; 0.6 → 2nd appearance × 0.36, 3rd × 0.22
    floor: float = 0.1   # never drop below this multiplier — popular authors can still appear
    # rule out a track of bad config:
    # assert 0.0 < decay < 1.0
    # assert 0.0 <= floor < 1.0

def apply_author_diversity(
    scored: list[tuple[UUID, float, UUID]],   # (item_id, score, author_id) — sorted DESC by score on entry
    config: DiversityConfig = DiversityConfig(),
) -> list[tuple[UUID, float, UUID]]:
    """Walk the scored list in order; for each item compute appearance index
    for that author (0, 1, 2, ...) and multiply score by
    (1 - floor) * decay**index + floor. Re-sort by adjusted score DESC and return.
    Pure function — no DB, no mutation of inputs."""
```

**Steps**
- [x] Find the existing per-author cap in [recommendation.py](backend/app/ai/recommendation.py) (look for "per_author" or "cap" near the final ordering pass) and read it for context — do **not** modify.
- [x] Implement `apply_author_diversity` per the spec.
- [x] Tests:
  - Empty list → empty list.
  - Single author, 5 items → multipliers `[1.0, 0.4 (=0.6+0.4×0.6^1), ...]` (verify exact arithmetic from formula).
  - Mixed authors → first item per author keeps multiplier 1.0.
  - Final order is by adjusted score DESC.
  - Floor honored: 100 items same author → smallest multiplier ≥ floor.
- [x] `pytest backend/tests/ai/test_diversity.py -v` passes.
- [x] Commit on `rec/author-diversity`. Update status box.

**Done when:** all checkboxes ticked, tests green.

---

## Track 5 — Writing → FeedItem Metadata Auto-Sync

**Hypothesis:** When an author edits title/description/cover/genres/tags on a Writing whose FeedItem is already published, the change should auto-propagate. Today it requires explicit republish, which means typos linger. Price/visibility/draft state are deliberately excluded — those remain explicit decisions.

**Owns (write):**
- The handler in `backend/app/routers/writings.py` (or wherever PATCH/PUT on writings lives — confirm at start of task)
- `backend/tests/routers/test_writings_metadata_sync.py` (new)

**Reads (no writes):**
- [feed_publish.py](backend/app/feed_publish.py) — uses `upsert_feed_item_for_writing` as-is
- [writing.py (model)](backend/app/models/writing.py)
- [feed_item.py (model)](backend/app/models/feed_item.py)

**Steps**
- [x] Find the writing update route: `grep -rn "def update_writing\|@router.patch\|@router.put" backend/app/routers/ | grep -i writing`.
- [x] Confirm the fields that should auto-sync: `title`, `description`, `cover_image_path → image_url`, `cover_image_meta → image_meta`. Confirm fields that must **NOT** sync: `price_cents`, `currency`, `visibility`, `is_draft`.
- [x] After the writing is saved in the route, check if a `FeedItem` with `writing_id = writing.id` exists (`SELECT 1`). If yes AND it's not a draft, call `upsert_feed_item_for_writing` with the new metadata (passing the existing publisher/visibility/price unchanged — fetch them from the existing row first).
- [x] Tests:
  - Update writing title without published FeedItem → no FeedItem created (no side effect).
  - Update writing title with published FeedItem → FeedItem.title updated.
  - Update writing description with draft FeedItem → FeedItem NOT updated (drafts stay frozen).
  - Update only non-syncing field (e.g. `target_word_count`) → FeedItem untouched.
- [x] `pytest backend/tests/routers/test_writings_metadata_sync.py -v` passes.
- [x] Commit on `rec/metadata-sync`. Update status box.

**Done when:** all checkboxes ticked, tests green. **This track is fully independent of Tracks 1-4 and the integration step** — it can ship on its own.

---

## Track 6 — Integration (Sequential, single owner)

**Run only after Tracks 1-4 are all merged to `main`.** This is the wiring pass — small, careful, and reviewed.

**Owns (write):**
- [recommendation.py](backend/app/ai/recommendation.py)
- `backend/tests/ai/test_recommendation_integration.py` (new)

**Steps**
- [x] Merge `rec/follow-signal`, `rec/seen-filter`, `rec/completion-signal`, `rec/author-diversity` into `main` (Track 5 can land independently).
- [x] At the top of [recommendation.py](backend/app/ai/recommendation.py), add:
  ```python
  from app.ai.signals.follow import (
      get_followed_author_ids, follow_boost, followed_author_candidates,
  )
  from app.ai.signals.seen import get_recently_seen_ids, filter_seen
  from app.ai.signals.completion import (
      get_completion_signals, apply_completion_to_profile,
      COMPLETION_WEIGHT, DEEP_SCROLL_WEIGHT,
  )
  from app.ai.signals.diversity import apply_author_diversity, DiversityConfig
  ```
- [x] In `_aggregate_profile` (or wherever user-signal weights are summed): after the existing aggregator runs, call `apply_completion_to_profile(profile_weights, completion_signals, item_metadata)`.
- [x] In the candidate-pool builder: add a 5th stratum that calls `followed_author_candidates(...)` and merges its ids into the pool.
- [x] In the scoring loop: after computing the existing score, add `score += follow_boost(item.author_id, followed_ids)`. Pre-fetch `followed_ids` once outside the loop.
- [x] Just **before** the existing diversity pass: call `candidates = filter_seen(candidates, seen_ids, keep_top_n=3)` to drop already-shown items (keep top 3 evergreens).
- [x] **Replace** the existing per-author cap with `apply_author_diversity(scored, DiversityConfig())`. Delete the old cap code.
- [x] Add an integration test that constructs a fake user with: 1 follow, 5 impressions, 1 completed item, multiple items from same author. Verify the served order matches the expected post-signal ranking.
- [x] Verify the existing recommendation tests still pass: `pytest backend/tests/ai/ -v`.
- [x] Smoke-test the live endpoint: `curl localhost:8000/api/feed/home` with a real user JWT and confirm the response shape is unchanged and items differ from the pre-integration baseline.
- [x] Commit on `main` with message `feat(rec): integrate follow/seen/completion/diversity signals — see recommendation_new.md`.

**Done when:** all checkboxes ticked, full backend test suite green, smoke test passes.

---

## Final acceptance

Tick when overall feature is shipped:

- [x] All 6 tracks complete.
- [x] No regression in `backend/tests/` (full suite green).
- [x] Manual: like 2 items, follow 1 author, complete 1 item → home feed visibly shifts on next reload.
- [x] Manual: refresh the home feed 3 times in a row → the items at the top differ (seen-filter working).
- [x] Manual: a single author with many items appears at most ~2-3 times in the first 20 cards (diversity working).
- [x] CTR observation: after 1 week of real traffic, `RecommendationEvent` CTR is **no worse** than baseline. (We expect a lift, but the bar to keep the change is "not worse.")

---

## Why these 5?

Picked using 80/20:

1. **Follow signal** — the strongest declared signal in the DB has zero weight today. Free win.
2. **Seen filter** — kills the #1 UX complaint of every new recsys (repeat content). The data already exists in `RecommendationEvent`.
3. **Completion signal** — `ReadingProgress.completed` is ground truth, currently ignored.
4. **Author diversity** — smoother than the existing hard cap; mirrors Twitter's exact heuristic; ~10 lines.
5. **Metadata auto-sync** — not from x-algorithm, but called out in the snapshot discussion. Independent track an agent can knock out in parallel.

Skipped from x-algorithm (low ROI at our scale):
- Phoenix two-tower neural retrieval (pgvector KNN already covers this conceptually).
- SimClusters / TwHIN graph embeddings (need way more graph data than we have).
- Realtime Kafka fan-out / Thunder (premature; on-demand follow query is fine until ~100k DAU).
- 19-task transformer ranker (the weighted-sum aggregator is the right shape for our scale).

---

## Kick-off script

Paste into the user's terminal once:
```bash
cd /Users/vijayshankar/Desktop/write
git worktree add .claude/worktrees/rec-follow-signal     -b rec/follow-signal     main
git worktree add .claude/worktrees/rec-seen-filter       -b rec/seen-filter       main
git worktree add .claude/worktrees/rec-completion-signal -b rec/completion-signal main
git worktree add .claude/worktrees/rec-author-diversity  -b rec/author-diversity  main
git worktree add .claude/worktrees/rec-metadata-sync     -b rec/metadata-sync     main
```

Then launch each agent with a prompt like:
> Read `recommendation_new.md` at the repo root. You are Agent **A** working on **Track 1 (Follow-Graph Signal)** only. Your worktree is at `.claude/worktrees/rec-follow-signal`. Do exactly the steps under Track 1, write only the files listed in `Owns`, and stop after committing on `rec/follow-signal`. Do not touch any other file.

Repeat with B/C/D/E and their respective tracks.
