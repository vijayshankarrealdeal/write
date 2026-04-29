# Book ingest agent — plan

PDF in → folder of structured JSON + illustrations on disk. A separate,
*manual* sync step pushes to MinIO + Postgres. Designed for 200–500 page
books without burning tokens.

## Layout

```
backend/test_model/
  plan.md                 # this file
  ingest_book.py          # CLI: python ingest_book.py /data/bible.pdf
  sync_to_db.py           # CLI: python sync_to_db.py bible   (manual, after review)
  regenerate_image.py     # CLI: python regenerate_image.py bible --query "..." --instruction "..."
  book_ingest/
    __init__.py
    config.py             # azure endpoints, image API key, budgets
    schemas.py            # pydantic types shared across phases
    pdf_loader.py         # PyMuPDF text extraction (no LLM)
    chunker.py            # TOC + heading heuristics → Chunk[] (no LLM)
    agents.py             # pydantic-ai Agent setup for map/reduce
    retry.py              # exponential backoff for transient API failures
    map_agent.py          # cheap pass: every chunk → ChunkBrief (per-item disk)
    reduce_agent.py       # deep pass: top-N chunks → ChunkDeep (per-item disk)
    embeddings.py         # per-chunk + per-scene vectors → embeddings/
    image_planner.py      # picks K best scenes globally (no LLM)
    image_gen.py          # wraps gpt-image-2 (lifted from test.ipynb)
    delta.py              # Quill Delta JSON builder for Section.content
    persist.py            # atomic writes; per-item briefs/deeps/embeddings
    db_publish.py         # creates random user, inserts Writing/Section/FeedItem
    pipeline.py           # orchestrates phases; resumable per-item
```

The package lives under `test_model/` for now to validate end-to-end on real PDFs (Bible first). Once stable it gets promoted to `app/ai/book_ingest/` and wired into a FastAPI router.

## The two-step user flow

1. **Ingest** (LLM-spending, disk-only):
   ```bash
   python ingest_book.py /data/bible.pdf
   ```
   Single arg. Title comes from the filename stem, slug too. Output goes
   to `storage/books/bible/` next to JSON dumps and PNGs. **Never touches
   Postgres or MinIO.**

2. **Sync** (side-effecting, run when you're happy with the dump):
   ```bash
   python sync_to_db.py bible
   ```
   Uploads images to MinIO, rewrites image URLs in section deltas to the
   public URLs, creates a random author user, inserts Writing + Sections,
   picks a random publisher user, inserts a FeedItem. Idempotent — passes
   `--force` to re-publish.

This split exists because the user explicitly wants to eyeball the JSON
+ images before any DB writes happen.

## Phases (during ingest)

| # | Phase            | Cost             | What it does |
|---|------------------|------------------|--------------|
| 0 | Load             | free             | PyMuPDF → `Page{no, text}` for every page; pull embedded TOC if present |
| 1 | Chunk            | free             | Group pages into chapters using TOC, else heading regex (`/^(CHAPTER\|BOOK\|PART) /i`); fallback 5-page sliding window |
| 2 | Map              | cheap chat model | For every chunk, return `ChunkBrief`. **Each chunk's brief is written to `briefs/<chunk_id>.json` as it completes** — resume only re-runs missing files |
| 3 | Reduce           | smart chat model | Top ~20% by importance. Returns `ChunkDeep`. **Per-chunk persistence** under `deeps/<chunk_id>.json` |
| 3.5 | Chunk embeddings | embedding model | One vector per chunk summary, written to `embeddings/chunk-<id>.json`. Resumable per item |
| 4 | Plan img         | free             | Score every scene = `chunk.importance × scene.visual_strength`; take top K |
| 4.5 | Scene embeddings | embedding model | One vector per planned scene_text → `embeddings/scene-<id>.json`. Powers `regenerate_image.py --query` |
| 5 | Generate         | gpt-image-2      | Call `generate_image()` for each picked scene; **PNG already on disk → skipped** |
| 6 | Persist          | free             | Write composite `chunks/<id>.json`, `highlights.json` |

Resilience: every per-item file is written via atomic rename (tempfile +
`os.replace`). A power cut leaves either the old file or the new file on
disk — never a half-written one. A `kill -9`, network drop, or 5xx blip
mid-pass loses at most one in-flight item; everything else stays.

Transient API failures (429, 5xx, timeouts, connection resets) auto-retry
with exponential backoff. Permanent errors (4xx other than 429) record
the failure for that item and let the rest of the run continue.

## Token budget (rough, 500 pages, ~250K input tokens)

- **Map** (cheap model): 250K in + 30K out → ~$0.25–$0.40 depending on deployment
- **Reduce** (smart model): top 20% = 50K in + 10K out → ~$0.90
- **Embeddings** (chunk summaries only, ~50 chunks × 200 tok): ~$0.01
- **Images** (cap 30 × ~$0.04): ~$1.20
- **Total**: ~$2.40–$3 / book

Bible-specific: cap images at 60 (more chapters worth illustrating); still under $4.

## Token-saving levers (in priority order)

1. **Cheap deployment for the map pass.** Non-negotiable when both deployments differ. Today both env vars point at `gpt-5.3-chat` (only deployment available); swap when something cheaper appears.
2. **Importance gate.** Top 20% by score, not a fixed threshold — predictable cost regardless of book.
3. **Hard image cap.** Per-book, not per-chapter. Prevents runaway spend on dense books.
4. **Stable system prompts.** Identical across all map calls so prefix caching kicks in.
5. **Resumable checkpoints.** `manifest.json` records each phase's completion. Crashed runs resume.
6. **Parallel map.** asyncio semaphore=8. Cuts 500-page wallclock from ~30 min to ~5 min.

## Reader-preference plumbing — "keep the user in mind"

Every image prompt is composed as

```
<scene>. <book-wide style>. reader preference: <user_text>. no text, no logos, ...
```

The same `--reader-preference "..."` flag also gets injected into the
reduce-agent's user message ("bias scene + highlight picks toward this"),
so the reader's taste shapes both **which** moments get illustrated and
**how** each illustration is rendered. Empty preference → no-op.

## Image style guidance

One consistent style per book, set at ingest time. Default: `"editorial illustration, muted palette"`. For Bible: `"renaissance fresco style, warm earth tones"`. Style is concatenated to every scene prompt so the book reads as a coherent visual whole.

## Quill Delta output

The Flutter app stores every section as a Quill Delta — a JSON list of
`{insert: ..., attributes?: {...}}` ops. The ingest pipeline (during sync)
builds these in `delta.build_section_delta`:

- The `rich_summary` from the deep pass becomes the opening italic paragraph.
- The first generated illustration is embedded right after, as `{insert: {image: "<url>"}}`.
- The chunk text is inserted with `{background: "#FFEB3B"}` (etc.) attributes
  on each highlight span. Spans are sorted, non-overlapping, and validated
  against character offsets so a hallucinated span gets dropped silently.
- Remaining illustrations are appended at the end with italic captions.
- The doc terminates in a trailing `\n` op, as flutter_quill expects.

Image `src` URLs are MinIO public URLs at sync time (the local file paths
are rewritten by the `image_url_for` callback in `sync_to_db.py`).

## Sync flow (`sync_to_db.py <slug>`)

1. Load `storage/books/<slug>/{manifest, chunks/*, images/*, plan}.json`.
2. **Upload images to MinIO** at `books/<slug>/<scene_id>.png` via
   `app.storage.upload_file`. Build `{local_path: public_url}`.
3. **Create a random author user** — random name from a small curated
   pool, generated `*.@inkx.local` email, non-loginnable password marker.
4. **Insert `Writing`** owned by that user. Cover = highest-scoring scene's
   public URL. `status="published"`, `writing_type="book"`.
5. **Insert one `Section` per chunk** with the Quill Delta as `content`
   (JSONB). Append IDs back to `Writing.section_ids`.
6. **Pick a random publisher user** — any existing user other than the new
   author; falls back to the author if the DB is empty.
7. **Insert a `FeedItem`** under the publisher with the embedded `sections`
   JSONB so the feed view renders without joining.
8. Write `manifest.synced = {author_user_id, writing_id, feed_item_id, publisher_user_id}`
   so re-running is a no-op (or `--force` to publish again).

## Output: `storage/books/<slug>/`

```
manifest.json                         # { title, author, slug, phases_done, image_budget, style, reader_preference, synced? }
pages/0001.json                       # raw page text
briefs/<chunk_id>.json                # one ChunkBrief per file — atomic, resumable
deeps/<chunk_id>.json                 # one ChunkDeep per file — atomic, resumable
chunks/<chunk_id>.json                # composite { chunk, brief, deep?, scene_ids[] }
images/<scene_id>.png                 # generated illustration
images/<scene_id>.json                # { prompt, chunk_id, scene_text, score, model, revision_history? }
embeddings/chunk-<chunk_id>.json      # { chunk_id, text, vector }
embeddings/scene-<scene_id>.json      # { scene_id, text, vector }
plan.json                             # full PlannedScene list (id, chunk, score, scene_text)
highlights.json                       # flat list of { chunk_id, start, length, color, why }
```

## Image regeneration (post-ingest, no full re-run)

`regenerate_image.py` swaps a single illustration without touching any
other state. Two ways to pick the target:

```bash
# By scene id (read off images/<scene_id>.png filename)
python regenerate_image.py bible 5b3f9a2c1e7d \
  --instruction "darker, storm clouds, more dramatic lighting"

# By natural-language query — the on-disk scene embeddings are searched
# semantically; the top matches are presented for confirmation
python regenerate_image.py bible \
  --query "the storm on the sea of galilee" \
  --instruction "dawn light breaking through clouds"

# See what scenes a query matches without spending image-API calls
python regenerate_image.py bible --query "burning bush" --dry-run
```

Behavior:

- Original prompt is preserved; the new instruction is appended as
  `... Modification: <instruction>`.
- Style + reader_preference are read from `manifest.json` so the new
  image keeps the book's visual voice.
- The previous PNG is moved to `images/<scene_id>.<timestamp>.bak.png`
  before the new one lands — easy revert with `mv` if the result is bad.
- `images/<scene_id>.json` accumulates a `revision_history` so each
  regeneration is auditable.
- No map/reduce LLM calls are made. The only cost is one image API call
  (and one embedding call when using `--query`).

## CLI cheatsheet

```bash
# 1) ingest (single arg is enough; resumes automatically if interrupted)
python ingest_book.py /data/bible.pdf

# ...with reader steering + bigger image budget
python ingest_book.py /data/bible.pdf \
  --reader-preference "painterly, mystical, warm light" \
  --style "renaissance fresco" \
  --image-budget 60

# 2) review storage/books/bible/ — open a few chunk JSONs and PNGs

# 3) (optional) tweak any image with new instructions
python regenerate_image.py bible --query "..." --instruction "..."

# 4) sync to MinIO + Postgres
python sync_to_db.py bible

# (Or skip MinIO for a dry DB write that uses file:// URLs)
python sync_to_db.py bible --no-images
```

## Local debug studio (single-page React)

A FastAPI server at [studio/server.py](studio/server.py) wraps every CLI
tool as an HTTP endpoint and serves a one-file React UI from
[studio/static/index.html](studio/static/index.html) (React + Babel
loaded from CDN — no build step). Run it locally:

```bash
# from backend/test_model/
./studio/run.sh
# or:
uvicorn studio.server:app --reload --port 8765
# then open http://localhost:8765/
```

The studio UI gives you:

- **Upload form** — drop a PDF, set image budget / style / reader
  preference, kicks off ingest as a background task.
- **Live progress strip** — counts of pages/briefs/deeps/embeddings/images
  as files land on disk, polled every 2 s.
- **Chunks tab** — every chapter's brief + deep summary + highlight spans.
- **Pages tab** — scroll the raw extracted text page by page.
- **Images tab** — thumbnail grid with a "Fix recommendation" button on
  each card (textarea → POST `/api/.../regenerate` → image refreshes
  in-place; previous PNG kept as `.bak.png`).
- **Delta tab** — renders the final Quill Delta the way the Flutter app
  will show it (italic summary, embedded images, highlight backgrounds),
  plus the raw Delta JSON in a collapsible.
- **Sync to DB + MinIO button** — calls `sync_to_db.py` under the hood,
  streams the output back into a collapsible.

Don't deploy it. CORS is wide open and there's no auth — it's a local
debug tool only.

## Throughput tuning

With $500 of Azure credits the constraint is wallclock, not cost. Defaults
in [book_ingest/config.py](book_ingest/config.py) are tuned for high-throughput Azure
deployments:

| Var                          | Default | Notes |
|------------------------------|---------|-------|
| `INGEST_MAP_PARALLELISM`     | 16      | Map calls are short; bump until you hit Azure TPM caps |
| `INGEST_REDUCE_PARALLELISM`  | 12      | Larger payloads, fewer items |
| `INGEST_IMAGE_PARALLELISM`   | 6       | gpt-image-2 typically has ~6 concurrent slots |
| `INGEST_EMBED_PARALLELISM`   | 16      | Embeddings are very cheap, can crank higher |

If you start seeing 429s, halve the offending number. Retry/backoff in
[book_ingest/retry.py](book_ingest/retry.py) handles transient blips automatically.

## Install

```bash
# from repo root, once:
cd backend
pip install -r requirements.txt          # main backend stack (fastapi, openai, pgvector, …)
pip install -r test_model/requirements.txt   # PyMuPDF + requests for the prototype
```

The studio + CLI scripts use the *same* venv as the backend so all
`from app.*` imports resolve.

## Required env (sourced from `.env` at repo root via `app.config.settings`
and `book_ingest.config`)

- `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_API_VERSION`
- `AZURE_OPENAI_MAP_DEPLOYMENT` — cheap chat (currently `gpt-5.3-chat`)
- `AZURE_OPENAI_REDUCE_DEPLOYMENT` — smart chat (currently `gpt-5.3-chat`)
- `AZURE_IMAGE_API_KEY`, `AZURE_IMAGE_ENDPOINT`, `AZURE_IMAGE_DEPLOYMENT`,
  `AZURE_IMAGE_API_VERSION` — for `gpt-image-2`
- `AZURE_OPENAI_EMBEDDING_DEPLOYMENT` — defaults to `text-embedding-ada-002`.
  **Optional** — if no embedding model is deployed on your Azure resource,
  the pipeline probes once, prints a one-line "skipping" message, and
  continues without semantic search. Set `INGEST_ENABLE_EMBEDDINGS=false`
  to silence the probe entirely. Without embeddings, `regenerate_image.py`
  + the studio image regen still work via direct `scene_id`; only the
  free-text `--query` shortcut is unavailable.
- `DATABASE_URL`, `MINIO_*` — only for `sync_to_db.py`

## Open questions

1. Re-sync semantics — does `--force` create a fresh row set or update the existing one? Currently: creates fresh. Easier and fine for prototype.
2. Image style override per chapter — useful for Bible (Genesis vs Revelation visually different), but adds complexity. Punt to v2.
3. Re-ingest with new budget — does it regenerate images or keep existing? Currently: keep (resumes from disk). Add `--force-images` later when needed.
4. Reader preference vs DB user identity — for the prototype the reader preference is a CLI flag; longer term it should pull from a logged-in user's preferences when ingest is exposed via the FastAPI router.
