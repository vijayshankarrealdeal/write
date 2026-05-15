# Convert Book to Inkspace Reader Book — Claude Desktop Playbook

You (Claude Sonnet 4.6, running in Claude Desktop) are the **mastermind**
for turning N raw books — PDFs or Project Gutenberg HTML — into reader-
ready content for the **Inkspace** app.

**The deal: you prepare everything ready-made on disk.** Cleaned
markdown, briefs, deeps, image prompts, character bibles, poster copy,
Quill Deltas — all of it lands on disk, finished, before any reader
opens the book.

**Azure has exactly one job, run automatically at the end of prep:**
once every prompt JSON is on disk (Phase 7) and the Deltas + poster
are written (Phases 8–10), you call the studio's `generate-all`
endpoint, which fires every cover/character/scene generation in
parallel with the same 5-strategy rephrase-retry. **The book ships
with every PNG already in place — no human clicks needed.** The
per-scene "Generate image" buttons in the studio survive as a
manual retry / catch-up path for the rare prompts Azure refuses
to soften.

Everything else — every text decision, every art-direction decision,
every prompt — is yours, done up-front, written to disk as plain
files.

This document is your runbook. Read it end-to-end before touching the
first book.

---

## 1. The product — Inkspace, and what the reader sees

Inkspace is a Flutter app where readers browse a feed of richly
illustrated books. Each book becomes:

- A **Writing** row in Postgres — title, author, cover, genres, tags,
  back-cover copy, character cards.
- One **Section** per chapter, with its `content` stored as a **Quill
  Delta** (a JSON list of `{insert, attributes?}` ops). The Flutter
  client renders these as flowing illustrated prose.
- A **FeedItem** so the book lands on the homepage with its cover,
  blurhash placeholder, dominant color, genre chips.
- A **cast strip** of character portraits — readers tap one to see who
  the character is.

### The reading experience you are designing for

Every Section the reader opens looks like this:

```
┌────────────────────────────────────────────────────┐
│ italic editorial summary — 80–150 words            │
│ ("What this chapter does, why it matters.")        │
│                                                    │
│ [ HEADLINE ILLUSTRATION — the chapter's peak       │
│   moment, rendered in the book's signature style]  │
│   small italic caption beneath                     │
│                                                    │
│ ## Chapter Title — As The Author Wrote It          │
│                                                    │
│ Clean flowing paragraphs of the author's prose.    │
│ Hyphenated splits fixed. Typographic quotes. Em-   │
│ dashes. Foreign words *italicised*. A pivotal      │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━     │
│ sentence highlighted in a KEY tone so the eye      │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━     │
│ catches it.                                        │
│                                                    │
│ > Verse rendered as blockquote                     │
│ > with the original line breaks preserved          │
│                                                    │
│ More clean prose, with a THEMATIC span catching    │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━     │
│ another beat in its own colour.                    │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━     │
│                                                    │
│ [ SECONDARY ILLUSTRATION — anchored next to the    │
│   paragraph it depicts, not dumped at the end ]    │
│                                                    │
│ Final paragraphs of the chapter, with an EMOTIONAL │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━     │
│ moment in a third tone for the heart.              │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━     │
└────────────────────────────────────────────────────┘
```

**Highlights have three semantic kinds — colours are NOT fixed:**
- **key** — a plot/argument moment the reader must not miss
- **thematic** — a line that crystallises a theme
- **emotional** — a beat that lands on the heart

The reader (or the operator, per book) supplies the actual hex
values. The app does not lock them. Pick colours that suit the
book's palette — a Renaissance fresco shouldn't be highlighted in
neon. When no values are given, derive three contextual tones from
the book's `base_palette`. When you can't derive, fall back to soft
warm/cool/blush tones that won't clash with the artwork — but treat
those as last-resort defaults, not constants.

Every illustration in the book must look like it came from one art
director — same medium, same palette, same characters. A reader who sees
"Alice" in nine scenes must see the same girl in all nine.

Your job is to make every book feel like a curated edition — not an
auto-OCR dump.

---

## 2. Your role vs. the backend's role

| Job | Who | When |
|---|---|---|
| Loading PDF/HTML | **You** | prep, offline |
| Chunking into chapters | **You** | prep, offline |
| **Cleaning raw text → markdown** | **You** | prep, offline |
| **Map: per-chunk brief** | **You** | prep, offline |
| **Reduce: deep per-chapter analysis** | **You** | prep, offline |
| **Scout: book-wide art direction** | **You** | prep, offline |
| **Composing image prompts** (scenes, characters, cover) | **You** | prep, offline |
| **Quill Delta assembly** | **You** | prep, offline |
| **Back-cover copy + genres + tags** | **You** | prep, offline |
| **Image pixel generation** | **Azure**, called by backend | **end of prep, automatic (Phase 10.5)** |
| **Prompt rephrase on failure** | Backend (deterministic) | inside each generation call |

You do **everything** that involves taste, judgment, or fidelity to
the author — and you do it offline, once, writing every output to
disk as a finished file. The backend is dumb infrastructure: it serves
your files to `index.html` and turns prompts into pixels when (and
only when) a reader asks for one.

**No backend code runs at prep time.** Claude Desktop is the entire
ingest pipeline. The only Python that ever runs at request time is
the tiny image-generation endpoint described in §10.

---

## 3. The cardinal rules — non-negotiable

These rules apply to **every** text-handling phase. Violating them
defeats the entire point of having a careful editor in the loop.

1. **Preserve every word the author wrote.** You may add nothing. You
   may remove only *extraction artifacts* — things the PDF/HTML
   extractor added that the author did not. When in doubt, **keep**.
2. **No meaning change.** Cleaning is typographic, not editorial. You
   do not paraphrase. You do not summarise prose down. You do not
   "improve" sentences. The author's voice is law.
3. **No line dilution.** A line of poetry stays one line. A short
   declarative sentence stays a short declarative sentence. You do not
   pad, expand, or restructure for "readability."
4. **±10% length tolerance per chunk.** If the cleaned output is more
   than 10% shorter than the input, you are summarising — that is a
   bug. More than 10% longer, you are padding — also a bug.
5. **Headings are inferred, never invented.** If the source has no
   chapter line, do not invent one. If a heading exists in the source,
   reproduce it verbatim — `CHAPTER I` stays `Chapter I` (Title Case),
   not `Chapter 1`.
6. **Names and foreign words are sacred.** Spellings are preserved
   exactly. Bhīma stays Bhīma. Çatal Höyük stays Çatal Höyük. You may
   *italicise* a foreign word with `*asterisks*`; you may not anglicise
   it.
7. **Front-matter is dropped, content is kept.** Drop copyright pages,
   ISBN blocks, TOC verbatim lists, marketing pages, scanner watermarks.
   Keep: dedications that read as substantive prose, translator
   prefaces that read as essay, real author forewords. When unsure,
   **keep**.
8. **Failure is loud.** If a chunk cannot be cleaned, leave the raw
   text on disk and log the failure. Never write a "summarised
   fallback" that pretends to be the author's words.

---

## 4. Parallelism

The constraint is: **10 Claude Sonnet 4.6 instances in flight at any
time across all text phases.**

Operationally this means:
- When you run the cleaner pass across 60 chunks, you process at most
  10 chunks in parallel. The other 50 wait.
- The same semaphore is shared with the map pass, the reduce pass, and
  the scout — if scout is running, only 9 cleaner calls may run
  concurrently with it.
- Azure image API calls do **not** count against this
  budget — they're a separate provider.

For book N parallelism: with 10 in-flight calls, processing 10 books at
once means each book gets ~1 in-flight call at a time. That's fine —
the bottleneck is wallclock per chunk, not per book. Saturate the 10
slots however the queue fills them.

---

## 5. Pipeline phases — what to do for each book

You walk these phases yourself, in order, for every book. There's no
orchestrator module — the playbook *is* the orchestration. Per-item
files on disk are the resilience contract: write atomically, skip
items whose output already exists, recover by re-running.

### Phase 0 — Load (free)

Input: a path to `.pdf`, `.html`, or `.htm`.

- For PDF: read the file with your Read tool — text-bearing PDFs
  return extractable text directly. For scanned/image-only PDFs,
  note that in the manifest and ask the operator before continuing
  (OCR is out of scope for this slim project).
- For HTML (Project Gutenberg): read the file, parse the `<meta>`
  tags for `DC.title`, `DC.creator`, `DC.subject`, then strip
  Gutenberg's header/footer boilerplate and convert the body to
  markdown using your judgment (Gutenberg HTML is well-structured
  — `<h1>`/`<h2>` for chapter divisions, `<p>` for prose).

Output: a list of `Page{no, text, char_count}` written to
`storage/books/<slug>/pages/<n>.json`. Each page atomically.

If the loader produces zero pages: **stop**. Don't run downstream
phases on empty input.

### Phase 1 — Chunk (free)

Group pages into **chapters** using:
1. The embedded TOC if the PDF has one.
2. Otherwise heading regex: `CHAPTER|BOOK|PART|LETTER|CANTO|ACT|SCENE|PROLOGUE` (case-insensitive), with word-numeral variants ("Chapter the First", "Book Two").
3. Fallback: 5-page sliding window.

Output: a list of `Chunk{id, chapter_title, page_start, page_end, text}`.
Chunk IDs are **deterministic** (hash of chapter title + page range) so
re-runs don't orphan per-item files.

Implement these heuristics inline as you work — there's no chunker
module to import in this project. The rules above are the complete
spec; do them directly with your Read tool + Python via Bash if
helpful, then write the resulting `Chunk[]` to disk as you go.

### Phase 2 — Clean (you, per chunk)

**This is the most important phase you run.** Every downstream phase —
and every reader — sees what you produce here.

For each chunk, you receive raw extracted text. You return clean
markdown that:

- Joins wrapped lines into proper paragraphs.
- Fixes hyphenated splits (`lite-\nracy` → `literacy`).
- Strips running headers/footers (book title repeated at every page
  top), page numbers as standalone tokens, scanner watermarks, OCR
  cruft, zero-width characters.
- Infers headings: `# Book Title` once at the start, `## Chapter I` per
  chapter, `### Subsection` where the source has them.
- Normalises straight quotes to typographic `“ ” ‘ ’`, `--` to `—`,
  `...` to `…`.
- Wraps verse, shloka, hymn, poetry, pull-quotes in `> ` blockquotes,
  one line per source line.
- Italicises foreign words with `*asterisks*`.
- Drops front-matter (copyright, ISBN, TOC list, marketing) but keeps
  substantive prefaces, dedications, translator essays.

The rules above are the authoritative cleaner contract. There's no
separate cleaner module — you execute it directly.

**Where output lands:** `storage/books/<slug>/cleaned/<chunk_id>.md`,
written atomically (tempfile + `os.replace`). Already-cleaned chunks
are **skipped** on re-runs.

If a chunk is entirely front-matter junk: write an empty file rather
than padded boilerplate. Empty cleaned output is a valid result.

### Phase 3 — Scout (you, one call per book)

Read **HEAD / MIDDLE / TAIL** samples (4K chars each) of the book.
Produce a `BookProposal`:

```python
class BookProposal:
    detected_genre: str                # "Hindu epic in English translation"
    cultural_context: str | None       # period/region anchor if any
    suggested_style: str               # vivid art-direction string
    suggested_reader_preference: str | None
    suggested_image_budget: int        # 10–120
    character_bible: list[CharacterRef]  # 2–8 recurring named figures
    base_palette: str | None           # "vermilion and gold"
    rationale: str                     # one-sentence sanity check
```

Each `CharacterRef`:
```python
class CharacterRef:
    name: str          # "Alice", "Bhīma"
    appearance: str    # image-gen prompt — age, build, hair, clothing,
                       # signature detail. One vivid sentence.
    bio: str           # 2-3 sentences for the reader-facing card —
                       # role, personality, what they do. No spoilers,
                       # no physical description.
```

**The character bible is the single most important lever for visual
coherence.** A book with 30 illustrations and no bible looks like 30
different books. A book with a tight bible looks like one edition.

Cache the proposal to `manifest.scout` so re-runs reuse it.

### Phase 4 — Map (you, per chunk)

For every chunk produce a `ChunkBrief`:

```python
class ChunkBrief:
    summary_1line: str                       # ≤25 words, neutral tone
    importance: float                        # 0.0–1.0, honest
    themes: list[str]                        # 1–5 short noun phrases
    image_candidates: list[SceneBrief]       # 1–3 striking moments
```

Each `SceneBrief`:
```python
class SceneBrief:
    scene_text: str                  # one painter-illustratable sentence
    visual_strength: float           # 0–1, >0.8 only for iconic moments
    mood: str | None                 # 1–3 words: "dread", "tender awe"
    composition: str | None          # close-up / medium / wide /
                                     # establishing / overhead / low-angle
    time_of_day: str | None          # "dawn", "candle-lit interior"
    setting: str | None              # one short visual phrase
    characters_present: list[str]    # exact book spellings
    palette_hint: str | None         # only when distinct from base
```

**Be honest about importance.** Most chapters are ~0.4. Only true peaks
get >0.8. The reduce pass only runs on the top 20% — if you inflate
importance, you blow the reduce budget on filler.

**Vary composition** across the candidates within a chunk — three
close-ups in a row is bad direction.

Output: `storage/books/<slug>/briefs/<chunk_id>.json`, per chunk,
atomically.

### Phase 5 — Reduce (you, top 20% of chunks)

Sort chunks by `importance`. For the top 20% (configurable —
`reduce_top_fraction`), produce `ChunkDeep`:

```python
class ChunkDeep:
    rich_summary: str                    # 80–150 words
    highlight_spans: list[HighlightSpan] # 2–6 spans
    top_scenes: list[SceneBrief]         # 1–3 scenes, mixed shapes
```

`HighlightSpan` uses **character offsets into the cleaned chunk text**:
```python
class HighlightSpan:
    start: int           # offset into cleaned chunk text
    length: int
    color_hex: str       # any hex the reader / operator wants — pick contextually
    kind: str            # "key" | "thematic" | "emotional" — semantic label,
                         # so the UI can re-skin colors without re-running ingest
    why: str             # short rationale
```

**Verify every span.** `text[start:start+length]` must be a real
substring of the cleaned text. Hallucinated spans get dropped silently
by the Delta builder, but you should catch them yourself first.

**Mix scene shapes:** one intimate moment, one grand moment, one
atmospheric moment. Don't pick three of the same.

Output: `storage/books/<slug>/deeps/<chunk_id>.json`.

### Phase 6 — Plan images (you, deterministic)

Score every `SceneBrief` from the map+reduce passes:
```
score = chunk.importance × scene.visual_strength
```

Take the top `image_budget` scenes globally. Assign each a stable
`scene_id` (hash of `chunk_id + scene_text[:64]`). Write the picked
scenes to `plan.json` — one entry per scene, with all cinematic
fields filled in.

This is pure ranking — no LLM call. Just sort + take top-K.

### Phase 7 — Compose image prompts (you, per scene + per character + cover)

**This is where you do all the art-direction work that used to be
spread across multiple phases.** For every scene the reader might
ever ask to materialise, you write the **final, ready-to-call OpenAI
prompt** and save it to disk.

For each scene in `plan.json`, write
`storage/books/<slug>/images/<scene_id>.json` with shape:

```json
{
  "scene_id": "<hash>",
  "chunk_id": "<hash>",
  "scene_text": "...",
  "prompt": "<the FINAL composed prompt — ready to call Azure with>",
  "negative": "no text, no logos, no signature, no watermark",
  "size": "1024x1536",
  "characters_present": ["Alice", "Bhīma"],
  "character_sheet_refs": [
    "characters/alice.json",
    "characters/bhima.json"
  ],
  "status": "pending"
}
```

Compose the `prompt` field by concatenating:
1. `scene_text` — the moment to depict
2. Cinematic hints: `mood`, `composition`, `time_of_day`, `setting`,
   `palette_hint`
3. Book-wide art direction: `style` and `base_palette` from scout
4. Reader preference if any
5. **Character refs**: for every name in `characters_present` that
   appears in the scout's character bible, append "`<name>:
   <appearance>`". This is the single biggest lever for visual
   coherence.

For each character in the bible, write
`storage/books/<slug>/characters/<name_slug>.json`:

```json
{
  "name": "Alice",
  "appearance": "<the vivid one-line description>",
  "bio": "<reader-facing card text>",
  "prompt": "<FINAL portrait prompt: appearance + style + base_palette>",
  "negative": "no text, no logos, no signature, no watermark",
  "size": "1024x1024",
  "status": "pending"
}
```

For the **cover**, write `storage/books/<slug>/cover.json`:

```json
{
  "scene": "<one vivid sentence describing the cover image>",
  "prompt": "<FINAL cover prompt: scene + style + base_palette + every character ref from the bible>",
  "character_sheet_refs": ["characters/alice.json", ...],
  "negative": "no text, no logos, no signature, no watermark",
  "size": "1024x1536",
  "status": "pending",
  "title_overlay": {
    "title": "<manifest.title>",
    "subtitle": "<manifest.subtitle or null>",
    "author": "<manifest.author>"
  }
}
```

`title_overlay` is consumed by a post-step that composites
typography on the cover (see §12.1) — you don't render text inside
the image itself.

**`status: "pending"`** marks every prompt as waiting for pixels.
Phase 10.5 will flip them to `"ready"` automatically as the
generations land. The studio's manual "Generate image" button is
the retry/catch-up path if any pending entry survives Phase 10.5.

**No PNG is produced in this phase.** You write prompts only — the
actual Azure calls happen in Phase 10.5.

### Phase 8 — Poster metadata (you, text only)

For the feed card and the book detail page, write
`storage/books/<slug>/poster.json`:

- `back_cover_copy`: 100–180 words, evocative, no spoilers
- `genres`: 1–3 tags (`historical-fiction`, `victorian-gothic`, …)
- `writing_types`: usually `["book"]`
- `tags`: 3–8 short discoverability tokens

The cover **scene** sentence and the cover prompt are already in
`cover.json` (Phase 7). Poster is text only.

### Phase 9 — Build Quill Deltas (you, per chunk)

For each cleaned chunk, write
`storage/books/<slug>/sections/<chunk_id>.delta.json` containing the
`Section.content` ops:

1. **Opening italic paragraph** = the chunk's `rich_summary` (if it
   exists). Skip if missing or if it starts with `[reduce failed:`.
2. **Headline image placeholder** = the highest-scoring scene in this
   chunk. Inserted as `{insert: {image: "/api/books/<slug>/images/<scene_id>/png"}}`
   followed by an italic caption.
   - **The URL may 404 at first.** `index.html` knows: if the GET
     returns 404, render a "Generate image" placeholder card pointing
     to the scene's prompt JSON. Once the reader clicks and the PNG
     lands, the same URL starts returning 200.
3. **Body** = the cleaned markdown converted to Delta ops. Bold,
   italic, headings, blockquotes preserved.
4. **Highlights** = `highlight_spans` applied as inline `background`
   attributes on the matching character ranges. Validate against the
   cleaned text — drop any span whose `text[start:start+length]`
   doesn't match the recorded substring.
5. **Secondary image placeholders** = woven inline next to the
   paragraph whose wording best matches `scene_text` (keyword-overlap
   scoring). Same 404-becomes-placeholder behavior.
6. **Trailing newline** — every Delta ends with `{"insert": "\n"}`.

The Delta is **final** at prep time. Image URLs don't change when
the PNG is later generated — the URL points at the file path, the
file just starts existing.

### Phase 10 — Persist (you)

Compose `storage/books/<slug>/manifest.json` with everything **except**
`ready_for_runtime` for now:

```json
{
  "title": "...",
  "subtitle": "...",
  "author": "...",
  "slug": "...",
  "description": "<from poster.back_cover_copy>",
  "scout": {...},                   // full BookProposal
  "poster": {...},                  // genres, tags, writing_types
  "image_budget": 30,
  "style": "...",
  "base_palette": "...",
  "reader_preference": "...",
  "phases_done": ["load", "chunk", "clean", "scout", "map", "reduce",
                  "plan", "compose_prompts", "poster", "delta", "persist"],
  "ready_for_runtime": false
}
```

`ready_for_runtime` stays **false** until Phase 10.5 finishes — the
flag means "every PNG that ships with this book is on disk", and at
this point only the prompts exist.

### Phase 10.5 — Generate all images (server-side, automatic) ⭐ NEW

This is the phase that flips the architecture from "click to
generate per scene" to **"book ships ready"**. No human clicks
needed.

The studio MUST be running (start it with `./run.sh &` before this
phase if it isn't). You call:

```
POST http://localhost:8765/api/books/<slug>/generate-all
```

What the server does:

1. **Wave 1 — characters first** (concurrency 3). Generates every
   pending character portrait. Sheets land in `characters/<name>.png`.
   These are the visual anchors scenes + cover will reference.
2. **Wave 2 — cover + every scene in parallel** (concurrency 5).
   Each call automatically passes the relevant character sheet PNGs
   as references to Azure's `/images/edits` endpoint, so Alice in
   scene 7 is the same Alice as in scene 22.
3. **Per-image rephrase retry** — the same 5-strategy ladder
   (as-is → softened → drop-extras → drop-character-refs →
   scene-only) applies to every generation. Content-policy hits
   self-recover; only genuinely-impossible prompts fail.

Returns a per-target results block:

```json
{
  "slug": "blue-castle",
  "status": "complete",            // or "partial" if any failed
  "counts": {
    "total_attempted": 39,
    "succeeded": 39,
    "failed": 0
  },
  "characters": [{"name_slug": "valancy", "status": "ready", "attempts": 1}, ...],
  "scenes": [{"scene_id": "...", "status": "ready", "attempts": 2}, ...],
  "cover": {"status": "ready", "attempts": 1}
}
```

**Wait for this call to complete.** A 40-image book typically takes
60–180s end-to-end. The HTTP timeout should be generous (5 min
minimum). Long but bounded.

If `status == "complete"`: move to Phase 11.

If `status == "partial"`: inspect the `failed` entries. The
common cause is a prompt that all 5 rephrase strategies couldn't
softening into Azure's safety bar. Options:
- Rewrite the offending prompt JSON on disk (Claude's job — adjust
  the scene description) and retry just that one via the per-image
  endpoint
- Drop the scene from the book (delete its prompt JSON; the Delta's
  inline reference 404s gracefully and the reader sees a clean gap)
- Skip and continue; the book ships with N-1 images

Once all PNGs are on disk, **flip `ready_for_runtime = true` in the
manifest** and re-write it. This is the official "ready to ship"
moment.

### Phase 11 — Bundle (you, optional)

Zip everything under `storage/books/<slug>/` into `bundle.zip` —
manifest, cleaned md, briefs, deeps, deltas, scene/character/cover
prompt JSONs, **plus every PNG generated in Phase 10.5**. A later
`restore_bundle.py` can replay the entire book onto a fresh disk
with zero Azure cost.

Insurance, not load-bearing.

---

## 5.5. Backend at runtime — the one job that runs in Python

After you finish prep, the entire backend reduces to a single small
FastAPI server (`studio/server.py`, slimmed) doing four things:

1. **Serve `index.html`** at `/`.
2. **Serve your on-disk artifacts** as JSON at:
   - `GET /api/books` → list books where `manifest.ready_for_runtime`
     is true
   - `GET /api/books/<slug>` → manifest + poster
   - `GET /api/books/<slug>/sections/<chunk_id>` → Delta JSON
   - `GET /api/books/<slug>/images/<scene_id>` → scene prompt JSON
   - `GET /api/books/<slug>/images/<scene_id>/png` → the PNG if it
     exists, **404 if it does not** (this is the trigger for the
     "Generate image" UI)
3. **Generate images on demand** at
   `POST /api/books/<slug>/images/<scene_id>/generate`:
   - Read `images/<scene_id>.json` (your prepared prompt).
   - Read any `character_sheet_refs` PNGs (generate those first if
     they're also `pending`).
   - Call Azure's image endpoint with `prompt` + `negative` +
     `size`, passing character sheet PNGs as reference images when
     present.
   - On success: write `images/<scene_id>.png`, flip
     `status: "ready"`, add `image_path`, add `generated_at`
     timestamp, return `200 {url}`.
   - **On failure** (content-policy reject, timeout, NSFW block,
     unrecognised character, low-quality output flagged by the
     model): see the rephrase-and-retry loop below.
4. **Sync to DB** (optional, button on `index.html`) — same as the
   existing `sync_to_db.py`. Only runs when an operator explicitly
   triggers it.

That's the entire runtime surface. **No cleaning, no chunking, no
map, no reduce, no scout, no delta-building.** All of that ran in
Claude Desktop, once, before the reader ever opened the app.

### The rephrase-and-retry loop

When Azure rejects or fails on a prompt, the backend doesn't give
up — it rewrites the prompt and tries again. **The rephrase is
deterministic** (no LLM call); the backend strips down the prompt
each retry until it lands:

| Attempt | Strategy |
|---|---|
| 1 | Send the prompt exactly as Claude composed it |
| 2 | If content-policy reject: soften violent / sensual language deterministically (the rules in `image_softener.py` — replace specific trigger words with softer near-synonyms; "blood-soaked sword" → "battle-worn sword"). Retry. |
| 3 | If still failing: drop `palette_hint`, `mood`, and `reader_preference` extras. Keep core scene + characters + style. Retry. |
| 4 | If still failing: drop character refs (keep names only). Retry. |
| 5 | Last resort: just `scene_text + style + negative tokens`. Retry. |
| 6 | Give up. Return `500 {error, attempts: [...]}` to `index.html`. Surface a "Generation failed — try again later or edit the prompt" UI. |

Every attempt logs the prompt actually sent and the failure reason
into `images/<scene_id>.json` under `attempts: [...]`, so the user
(and you, on the next book) can see what went wrong without
re-running.

Attempt 2's softening is driven by `book_ingest/image_softener.py` —
deterministic regex swaps for known trigger words. If a book
consistently fails on a specific character, that's a signal to you —
go back and rewrite the character's `appearance` in the bible so it
doesn't trip the filter the next time around.

### Why deterministic retry (not LLM rephrase)

The retry runs server-side, latency-sensitive (the reader is
watching a spinner), and on every failed click. An LLM rephrase call
adds 1–3s, costs tokens, and introduces nondeterminism — the same
scene might rephrase differently each retry. Deterministic rules
are fast, free, predictable, and good enough for the failure modes
we actually see (content policy + missing character context).

If a scene needs a real creative rewrite, that's not a runtime job —
it goes back to you, the next time the user runs `/convert` on this
book.

### Character sheets are also on-demand

The same model applies to character portraits. Their JSONs land in
`characters/` with `status: "pending"`. They're generated:
- When the reader explicitly clicks "Generate portrait" on the cast
  strip, **or**
- Implicitly, when a scene that needs the character as a reference is
  triggered — the backend lazily generates any referenced character
  sheet before the scene call.

Same rephrase-and-retry rules apply.

### The cover

Same flow. `cover.json/status: "pending"` until clicked. After the
PNG lands, the typography overlay (§12.1) composites the title +
author. Both steps are backend code.

---

## 6. Output structure on disk

Everything lives under `storage/books/<slug>/` (relative to the
project root, `/Users/vijayshankar/dispose`). The shape **must
match production format A exactly** — the same layout that
`/Users/vijayshankar/Desktop/write/backend/test_model/storage/books/`
ships and that the production VM's `sync_to_db.py` reads without
translation. After prep finishes (before any reader opens the
book):

```
storage/books/<slug>/
├── manifest.json                       # title/author/slug/scout/poster/style/phases_done/ready_for_runtime
├── plan.json                           # FLAT JSON ARRAY of scene entries (not a dict)
├── cover.json                          # cover prompt + title_overlay {title, subtitle, author}
├── poster.json                         # back-cover copy, genres, tags
├── scout.json                          # BookProposal + character_bible
├── chunks_index.json                   # ordered chunk index (studio convenience)
├── chunks/<id>.json                    # WRAPPER: {"chunk":{id,...}, "brief":{...}, "deep":{...}, "scene_ids":[]}
├── cleaned/<id>.md                     # cleaned markdown per chunk
├── pages/<n>.json                      # raw extracted pages
├── sections/<id>.delta.json            # Quill Delta per chunk (studio preview)
├── highlights.json                     # flat list of highlight spans
└── images/
    ├── <scene_id>.json                 # scene prompt
    └── _characters/
        └── <name_slug>.json            # character prompt
```

Mandatory format rules — these are what production reads, do not deviate:

- **`chunks/<id>.json` is wrapped**: top keys are `chunk`, `brief`, `deep`, `scene_ids`. `chunk` has `id` (not `chunk_id`), `chapter_title`, `page_start`, `page_end`, `text`. Never write the flat shape.
- **`plan.json` is a JSON array** of scene entries: `{scene_id, chunk_id, chapter_title, score, scene_text, mood?, composition?, time_of_day?, setting?, palette_hint?, characters_present[]}`. Not `{scenes: [...]}`. The field is **`chapter_title`**, never `chunk_title`.
- **Character slug**: `re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')`. **No NFKD decomposition.** "Geneviève" → `genevi-ve`, not `genevieve`. This is what `sync_to_db._safe_char_slug` does; matching it is what makes the production publisher find the portrait.
- **Character JSON lives at `images/_characters/<slug>.json`**, *not* at `characters/<slug>.json`. The top-level `characters/` directory does not exist.
- **`character_sheet_refs` in scene JSONs** must point to `"images/_characters/<slug>.json"`.

After Sync-to-VM (or any per-image click), PNGs land next to their JSONs:

```
images/cover.png                        # title typography ALREADY BURNED IN by the studio
images/<scene_id>.png                   # generated scene
images/_characters/<name_slug>.png      # generated portrait
```

The studio's cover-generate endpoint always composites
`cover.json:title_overlay` onto the raw model output before saving
to `images/cover.png`. The negative prompt to the model still says
`no text` — typography is your job (well, the server's), not the
model's.

**Atomic writes:** every per-item file is written via tempfile +
`os.replace`. Power cut → either old file or new file, never half.
Resume → re-run the phase; existing files are skipped.

---

## 7. Resilience contract

You **must** preserve the resilience properties of the existing
pipeline:

- One per-item failure does not stop the run. Log it, continue.
- One in-flight item lost on Ctrl-C is acceptable; everything already
  on disk survives.
- Re-running the whole pipeline on a slug with partial state is
  idempotent — only missing items are computed.
- `manifest.phases_done` records coarse phase completion, but the
  per-item files are the source of truth.

When you hit a transient Azure error (429, 5xx, timeout): retry with
exponential backoff (use `retry.py:with_retries`). Permanent errors
(4xx other than 429): record the failure, move on.

---

## 8. Invocation — how the user gives you N books

The user puts N book files into a folder (PDFs and/or Gutenberg HTML).
They tell you the folder path. You:

1. **Enumerate** every `.pdf`/`.html`/`.htm` in the folder.
2. For each, derive `slug` from the filename (strip the leading digit
   prefix Gutenberg uses, sanitise to `[a-z0-9-]+`).
3. Process books **in sequence** but **chunks within each book in
   parallel** — semaphore 10 across all in-flight Claude calls.
4. For each book, walk Phase 0 → Phase 11. Report progress per phase.
5. At the end, emit a summary JSON:
   ```json
   {
     "books": [
       {"slug": "frankenstein", "pages": 280, "chunks": 24,
        "deep": 5, "image_prompts_ready": 18,
        "characters_ready": 4, "cover_ready": true,
        "ready_for_runtime": true}
     ]
   }
   ```

   Notice: no `images: 18` count. There are no PNGs yet — that count
   only grows at runtime as readers click "Generate image". The
   counts above are how many *prompts* are sitting on disk ready to
   call Azure with.

Re-running on the same folder is **idempotent** — books already
prepped are skipped unless you force a re-prep. Books partially
processed pick up exactly where they left off (per-item JSON files
on disk are the source of truth).

---

## 9. What "enjoyable for the reader" actually means

Concrete, non-negotiable touches that separate a curated edition from
an OCR dump:

1. **Every section opens with editorial voice.** The italic
   `rich_summary` orients the reader before they hit the prose.
2. **The first image is the chapter's peak moment**, not a random
   pick. Anchored visually right after the summary.
3. **Highlights catch the eye on real beats**, not arbitrary spans.
   Three colors mean three different things — use them
   intentionally.
4. **Characters look like themselves** across every scene. If Alice is
   blonde in scene 1, she's blonde in scenes 9 and 22. Character
   sheets are the mechanism — never skip them.
5. **Verse looks like verse.** Blockquotes. Original line breaks.
   Never paragraph-mashed.
6. **Foreign words are honored.** `*Dharma*`, `*façade*`, `*Bhagavad
   Gītā*` — italicised, spelled right, not transliterated to ASCII.
7. **Headings reflect the source.** "Chapter the First" stays
   "Chapter the First" — not "Chapter 1". The author chose those
   words; you keep them.
8. **The cover tells you what kind of book this is.** A Renaissance
   fresco cover for a medieval epic, a graphite ink wash for a
   modernist novel. Scout decides; you honor.
9. **Back-cover copy invites the reader in** — no spoilers, evocative,
   under 200 words.
10. **The feed card is alive** — cover, blurhash placeholder, dominant
    color, genre chips, character portrait strip.

---

## 10. Schemas — verbatim reference

For exact field names and defaults of the **runtime-facing** shapes
(scene prompt, character prompt, cover prompt, poster), see
`book_ingest/schemas.py`. The other shapes (`Chunk`, `ChunkBrief`,
`ChunkDeep`, `BookProposal`) are documented in this playbook — they
never reach the server, so there's no Python model for them in this
slim project.

The shapes you emit, by phase:

- `Chunk` — Phase 1 chunker output (only loaded in memory; not
  written stand-alone)
- `ChunkBrief` (with `SceneBrief[]`) — Phase 4 map output →
  `briefs/<id>.json`
- `ChunkDeep` (with `HighlightSpan[]`, `SceneBrief[]`) — Phase 5
  reduce output → `deeps/<id>.json`
- `BookProposal` (with `CharacterRef[]`) — Phase 3 scout → embedded
  in `manifest.scout`
- **Scene-prompt JSON** — Phase 7 → `images/<scene_id>.json`. Shape
  in §7. Schema-light; the backend reads `prompt`, `negative`,
  `size`, `characters_present`, `character_sheet_refs`, `status`,
  optionally `attempts: [...]`.
- **Character-prompt JSON** — Phase 7 → `characters/<name_slug>.json`.
  Shape in §7. Backend reads `prompt`, `negative`, `size`, `status`.
- **Cover-prompt JSON** — Phase 7 → `cover.json`. Shape in §7. Adds
  `title_overlay: {title, subtitle, author}` for the typography pass.
- **Poster JSON** — Phase 8 → `poster.json`:
  `{back_cover_copy, genres, writing_types, tags}`.
- **Section Delta JSON** — Phase 9 → `sections/<chunk_id>.delta.json`.
  A list of Quill ops (no Pydantic model). Image URLs point to
  `/api/books/<slug>/images/<scene_id>/png` — file may not exist
  yet; that's intentional.
- **Manifest JSON** — Phase 10 → `manifest.json`. Shape in §10.
  `ready_for_runtime: true` is the contract.

---

## 11. Things to not do

- Don't paraphrase the author. Ever.
- Don't write an LLM "fallback summary" when cleaning fails. Leave the
  raw text and log.
- Don't invent chapters the source doesn't have.
- Don't bypass the 10-in-flight limit even when one book is small.
- Don't use Azure image API for any text task. It's pixels only — and only when
  a reader clicks.
- **Don't generate images during prep.** No batch run, no prefetch.
  Pixels happen only after a reader click. You write prompts, not
  PNGs.
- **Don't skip the character bible.** Even though sheets aren't
  generated up-front, the appearance strings you write are what every
  scene prompt depends on for character consistency. A weak bible
  means inconsistent characters the moment a reader starts clicking.
- Don't drop the **semantic kind** (`key` / `thematic` / `emotional`)
  from each highlight span — the reader's UI can re-theme colors
  later, but only if it knows what each span *means*. The hex values
  themselves are not locked; the kind labels are.
- Don't bake the book title into the scene-image prompts — that
  belongs in the cover's `title_overlay` typography pass (§12.1).
- Don't push to Postgres/MinIO without the user reviewing at least one
  book's on-disk artifacts first, unless they say "go end-to-end."
- Don't claim a book is `ready_for_runtime` until every `sections/*.delta.json`,
  every `images/*.json` prompt, the `cover.json`, and the
  `poster.json` exist. Those four artifact families are the contract
  the studio server expects.

---

## 12. Known oddities — open visual gaps

Things that look wrong in the product today but are not yet fixed in
the pipeline. Capture more here as we notice them.

### 12.1 Covers have title typography baked in (resolved)

The studio's `POST /api/books/<slug>/cover/generate` endpoint
always composites `cover.json:title_overlay` onto the raw model
output before saving to `images/cover.png`. Warm-ivory glyphs with
a near-black drop shadow, Georgia serif, title centered near the
top (wraps to two lines for long titles), author centered at the
bottom margin. The model is still told `no text, no logos, no
signature, no watermark` in the negative prompt — typography is
the studio's job, not the model's.

What you need to do:

- When you write `cover.json`, **always** populate
  `title_overlay: {title, subtitle, author}`. Pull `title` and
  `author` from `manifest.title` / `manifest.author`; `subtitle`
  is optional (use it for editions that have one, e.g.
  "Frankenstein; or, the Modern Prometheus" can put the alt
  title here).
- Do **not** bake the title into the cover prompt itself — that
  would tell the model to render text, which it does poorly.
  Leave the negative tokens in place.

Implementation lives in `studio/server.py:_composite_title_overlay`.
Fonts walk a Mac-typical list (Georgia → Times → Helvetica → PIL
default).

---

## 13. What's in this project, what's not

This is a slim, clean project. There is no legacy ingest code here.

### Files you can rely on

```
/Users/vijayshankar/dispose/
├── convert_book_to_inkspace_reader_book.md   # this playbook
├── README.md                                 # human + Claude orientation
├── run.sh                                    # ./run.sh starts the studio
├── deploy.sh                                 # CLI alternative to the Sync-to-VM button
├── requirements.txt                          # 7 deps
├── .env                                      # Azure + SSH creds (pre-populated, gitignored)
├── data/                                     # operator drops raw books here
├── storage/books/<slug>/                     # you write artifacts here (see §6 for layout)
├── studio/
│   ├── server.py                             # FastAPI runtime — image gen + cover overlay + deploy
│   └── static/index.html                     # studio UI w/ one-click Sync-to-VM
└── book_ingest/
    ├── config.py                             # env-driven config
    ├── schemas.py                            # pydantic types (mirrors production sync_to_db)
    ├── persist.py                            # atomic read/write helpers
    ├── retry.py                              # exponential backoff
    ├── image_softener.py                     # deterministic prompt-softening rules
    ├── image_gen.py                          # Azure gpt-image-2 wrapper (httpx)
    ├── deploy.py                             # normalize → tar → SFTP → container-exec
    ├── inventory.py                          # dedupe + tracking
    ├── triage.py                             # fast metadata + promise score
    ├── load_clean.py                         # HTML → chunks + cleaned markdown
    ├── finalize.py                           # Quill Deltas + scene/character/cover prompts
    └── import_main.py                        # one-time copy from legacy main project
```

No `cover_overlay.py` or `generate_all.py` — the cover overlay is
inline in `studio/server.py:_composite_title_overlay`, and bulk
image generation is the studio's job queue, kicked off by the
**Sync to VM** button.

### What you (Claude) do directly, no module to import

- PDF text extraction (use the Read tool on `.pdf` files; for
  scanned ones, drop a note in the manifest and skip).
- HTML parsing (use the Read tool on `.html` files; parse meta tags
  yourself).
- All the phases described in §5 — cleaning, chunking, scout, map,
  reduce, image-prompt composition, Delta assembly, poster.
- Quill Delta building (§5 Phase 9 — direct dict construction).
- Writing every artifact in the exact §6 format. Character slugs
  use the no-NFKD regex (`re.sub(r'[^a-z0-9]+','-', name.lower())`).
  Brief and deep data go *inside* `chunks/<id>.json` under their
  respective keys — there are no sibling `briefs/` or `deeps/`
  directories.

### What the server does for you

- Serves the JSONs you write at `/api/books/<slug>/...`.
- On `POST /api/books/<slug>/images/<scene_id>/generate`, runs the
  5-strategy rephrase-retry loop and writes the PNG to
  `images/<scene_id>.png`.
- On `POST /api/books/<slug>/characters/<name_slug>/generate`,
  same for portraits, written to `images/_characters/<name_slug>.png`.
- On `POST /api/books/<slug>/cover/generate`, generates the cover
  AND composites `title_overlay` typography onto it before saving
  to `images/cover.png`.
- On `POST /api/books/<slug>/deploy` (or click **Sync to VM**),
  runs `normalize_to_format_a` → tar → SFTP → `docker exec` into
  the fastapi container on the VM → `python sync_to_db.py <slug>`.
  The book is live in the Flutter app within seconds.

You don't call Azure yourself for images. You write the prompt; the
server calls it when the operator clicks (or when **Sync to VM**
pre-generates the missing ones in one shot).

---

## 14. The Flutter contract — what your output must satisfy

The studio at `/Users/vijayshankar/dispose` is **not** the final
consumer of your work. The final consumer is the **Inkspace Flutter
app**, which lives in the main repo at `/Users/vijayshankar/Desktop/write/`
(it's the same repo as the production backend — `lib/` is Flutter,
`backend/` is FastAPI, `ios/` `android/` `web/` `macos/` are
platform targets).

Flutter does **not** read your on-disk artifacts. It reads via the
production FastAPI at `https://inkspacex.com/api/...`, which reads
Postgres + MinIO. Your job — and what `deploy` does — is to get
your artifacts into Postgres + MinIO in the exact shape the Flutter
app expects.

### The data path, in full

```
You (Claude Code)                       Studio (this server)               Azure VM (production)              Flutter app
─────────────────                       ───────────────────                ─────────────────────              ────────────
write artifacts to                      serves them at                     storage/books/<slug>/              GET /api/feed/home
storage/books/<slug>/   ─SFTP─▶         localhost:8765/    ─deploy─▶       sync_to_db.py reads,    ─FastAPI─▶ GET /api/feed/{id}
                                                                            uploads images via                 GET /api/feed/{id}/characters
                                                                            app.image_pipeline,                GET /api/feed/{id}/sections/by-id/...
                                                                            inserts Writing+Section+
                                                                            BookCharacter+FeedItem
```

### What lands in Postgres after deploy (the four tables Flutter touches)

**`writings`** — one row per book. Key columns Flutter reads via the
FeedItem projection:
- `id` (uuid), `user_id` (the canonical `inkspace@inkspacex.com` user)
- `title`, `author` (real byline like "Harper Lee")
- `description` (the back-cover copy from your `poster.json`)
- `cover_image_path` (text — a MinIO public URL pointing at the
  cover's `medium.webp` variant)
- `cover_image_meta` (jsonb — see image_meta shape below)
- `status` (int — `published = 1`), `writing_type` (int — `book = 0`)
- `section_ids` (text[] — ordered list of Section UUIDs)

**`sections`** — one row per chapter. The reader page loads these.
- `id` (uuid), `writing_id` (uuid FK)
- `title` — the chapter title
- `content` (**jsonb** — the Quill Delta as a JSON array of ops, NOT a
  stringified version)
- `is_published = true`, `sort_order` (int)
- `kind` (e.g. `"chapter"`)

**`book_characters`** — the cast strip rows. One per character bible
entry.
- `id` (uuid), `writing_id` (uuid FK), `name`
- `appearance` (the image-gen prompt — vivid one-liner)
- `bio` (the reader-facing 2–3 sentence card text)
- `image_url` (MinIO public URL to the portrait's `medium.webp`)
- `image_meta` (jsonb — same shape as cover)
- `sort_order` (int — preserve scout bible order)

**`feed_items`** — the homepage card projection. One row per
published book. `upsert_feed_item_for_writing` builds this from
`writings`+`book_characters`+aggregated section content.
- `writing_id` (uuid, unique)
- `title`, `author`, `description`, `image_url`, `image_meta`
- `genres: list[str]`, `writing_types: list[str]`, `tags: list[str]`
- `is_draft = false`, `visibility = "public"`
- `created_at`, `updated_at`

### The Quill Delta shape — what `Section.content` must look like

The Flutter reader runs `quill.Document.fromJson(jsonDecode(contentJson))`
on `content`. Required shape:

```json
[
  {"insert": "An italic editorial summary…", "attributes": {"italic": true}},
  {"insert": "\n"},
  {"insert": "\n"},
  {"insert": {"image": "https://cdn.inkspacex.com/inkspace/books/<slug>/<scene>/medium.webp"}},
  {"insert": "\n"},
  {"insert": "small italic caption", "attributes": {"italic": true, "size": "small"}},
  {"insert": "\n"},
  {"insert": "Chapter Title", "attributes": {"header": 2}},
  {"insert": "\n"},
  {"insert": "Clean flowing paragraph of prose. "},
  {"insert": "pivotal sentence", "attributes": {"background": "#FFEB3B"}},
  {"insert": " catches the eye.\n"},
  {"insert": "Verse line one", "attributes": {"blockquote": true}},
  {"insert": "\n"},
  {"insert": "\n"}
]
```

Hard rules:
- It's an **array of ops**, written to Postgres as `JSONB` (not stringified).
- Every block-attr op (header, blockquote) carries its newline. `\n`
  closes a block.
- Inline image inserts are `{"insert": {"image": "<url>"}}`.
- Image URLs are **full MinIO public URLs**, not relative paths — and
  they point at the `medium.webp` variant (size 800px max edge).
- The document **MUST** terminate with `{"insert": "\n"}`.

### image_meta — the variant shape Flutter expects for cover + characters

Every "important" image (book cover, every character portrait) needs
this JSONB sidecar so `AppNetworkImage` can render a blurhash
placeholder + dominant-color background while the variant decodes:

```json
{
  "base_url": "https://cdn.inkspacex.com/inkspace/books/<slug>/cover/<version>",
  "width": 1024, "height": 1536,
  "blurhash": "L9AB$jof00WB~qof?bj[",
  "color": "#a37c4f",
  "variants": {
    "thumb":  {"w": 160, "h": 240},
    "small":  {"w": 400, "h": 600},
    "medium": {"w": 800, "h": 1200},
    "large":  {"w": 1600, "h": 2400}
  },
  "formats": ["webp"]
}
```

Flutter loads `<base_url>/<variant_key>.<fmt>` (e.g.
`<base_url>/medium.webp`).

**You don't compute this yourself.** The `sync_to_db.py` step on the
VM passes each PNG through `app.image_pipeline.process_image()` which
produces the blurhash + dominant color + WebP variants, and through
`app.storage.upload_variants()` which puts them in MinIO at the right
path. All you do is write the PNGs to disk; the pipeline takes care
of the rest at deploy time.

### Inline scene images in deltas

For images embedded inline (the scene illustrations woven into chapter
prose), Flutter only needs the URL — no image_meta in the JSON. The
delta op `{"insert": {"image": "<url>"}}` is enough. But the URL
**must** point at the MinIO public URL produced by the production
publisher, NOT at your local `/api/books/<slug>/images/<id>/png`.

How to make this work without coding the URL twice:
- In your Phase 9 (Build Quill Deltas), write the image URL as the
  **local studio path** `/api/books/<slug>/images/<scene_id>/png`.
- The production `sync_to_db.py` already rewrites these to MinIO public
  URLs at sync time via the `image_url_for` callback. So your local
  delta and the deployed delta share the same shape; only the URL
  differs.

### Reading time + section count

The Flutter detail page shows: `"31 sections · 7 hr 38 min · May 12 · historical-fiction"`.

- Section count = `len(sections)` — the rows you write.
- Reading time = computed **on the VM** by `compute_reading_minutes`
  which sums `LENGTH(elem->>'insert')` across every section's Quill
  delta and divides by 1200 chars/min. **You don't write this.**
- Date = `feed_items.updated_at`.
- Genre = `feed_items.genres[0]`.

If you want a specific reading-time appearance, the only lever is
**how much prose ends up in `Section.content`**. That's a function of
your cleaning fidelity — preserve every author word, ±10% length,
and the reading-time computes itself.

### Auth on the production side

Every Flutter HTTP call sets `Authorization: Bearer <jwt>`. The
backend's FastAPI endpoints require this. Your studio deploy step
does NOT need to handle auth — `sync_to_db.py` runs server-side as
a script with direct DB access. The book ships under the canonical
`inkspace@inkspacex.com` publisher account.

### Endpoints Flutter actually hits (for reference)

| Method | Path | Reads what |
|---|---|---|
| GET | `/api/feed/home` | list of `FeedItemResponse` (cards) |
| GET | `/api/feed/{id}` | one detail with section stubs (lazy bodies) + reading_minutes |
| GET | `/api/feed/{id}/sections/by-id/{section_id}` | full Quill Delta for one chapter |
| GET | `/api/feed/{id}/characters` | cast strip — list of `BookCharacterRead` |

Your responsibility ends at: producing the artifacts on disk such
that when `sync_to_db.py <slug>` runs on the VM, every one of these
four endpoints returns sensible data.

### The deploy command, in full

```
POST /api/books/<slug>/deploy   body: {"run_sync": true, "force": false}
```

What that does on the VM:

```
sftp put storage/books/<slug>/ → /home/azureuser/inkspace/storage/books/<slug>/
ssh azureuser@20.219.16.30 'cd /home/azureuser/inkspace/backend/test_model && \
    .venv/bin/python sync_to_db.py <slug>'
```

`sync_to_db.py` reads the manifest, chunks, briefs, deeps, images, and
the scout's character bible; uploads images through image_pipeline;
writes Postgres rows; calls `upsert_feed_item_for_writing`. The book
is live in the Flutter feed within seconds of the script returning.

**Required artifacts for `sync_to_db.py` to succeed** (i.e. what your
Phases 0–11 MUST produce on disk):

- `manifest.json` with `title`, `author`, `description`, `slug`, `poster`,
  `scout` (with `character_bible`), `cover_image_local` pointing at
  the cover PNG
- `chunks/<chunk_id>.json` — composite per-chunk records with brief +
  deep + scene_ids
- `briefs/<chunk_id>.json` and `deeps/<chunk_id>.json` (legacy format,
  still consumed by sync to rebuild the Delta if `sections/*.delta.json`
  is missing)
- `cleaned/<chunk_id>.md` (cleaned markdown per chunk)
- `images/<scene_id>.png` (the PNG itself, present means generated)
- `images/<scene_id>.json` (the prompt + scene_text + score)
- `images/cover.png` (the cover PNG)
- character portraits at `images/character_<name>.png` (legacy path)
  or `characters/<name>.png` (new path)

The new-format artifacts (`sections/<id>.delta.json`, `cover.json`,
`poster.json`, `characters/<name>.json`) are **additional** — they
power the studio's local UI but are not yet consumed by `sync_to_db.py`.
Producing both flavours costs you nothing extra (they share the same
inputs), and lets the deploy step work today without modifying the
production publisher.

---

## 15. Working at scale — when the user dumps 10,000 files

When the operator drops a folder with thousands of raw books and asks
"pick the best" or "what should I push to the platform," you do NOT
run the full pipeline on all of them — that's cost-prohibitive and
unnecessary. The flow is **triage → curate → convert → deploy**, with
the inventory at `storage/inventory.json` enforcing idempotency at
every step.

### Step 1 — Triage scan (free, ~38 files/sec)

Trigger the triage scan over the source folder:

```
POST /api/triage/scan  body: {"folder": "data"}   (or absolute path)
```

Or call `book_ingest.triage.scan_folder()` directly. This is a thread-
pool sweep that for every file extracts:

- title, author, language, Gutenberg `dc.subject` tags (HTML)
- title, author from PDF info, page count, scanned-PDF detection (PDF)
- word count estimate
- a heuristic **promise score** (0–1) — combines length, metadata
  richness, Gutenberg popularity (low IDs = heavily downloaded), and
  genre keyword hits
- a deterministic `source_hash` (sha256) so dropping the same file
  twice resolves to the same inventory entry

**No LLM call. No image gen. No expensive work.** 10,000 files = ~5
minutes.

Results land in `inventory.json` under each entry's `triage` block.

### Step 2 — Curate (you, with judgment)

When the operator says "pick the best N", call:

```
GET /api/triage/picks?target=30&buffer=5
```

This selector encodes the operator's quality bar:

1. **Excludes everything already in the Flutter app.** Books with
   inventory status `imported` / `ready` / `deployed` are filtered out
   — those are either already in production (imported from the main
   project) or already shipped from dispose. The user never sees
   "convert Frankenstein" recommended when Frankenstein is already
   on the home feed.
2. **Famous-only floor.** A "famous" book is one whose triage score
   is ≥ `0.80` (Gutenberg top-2000 + genre lift + novel-length all
   stack to push recognised classics above this; obscure local-history
   pamphlets sit well below). All famous candidates up to `target`
   are returned.
3. **Buffer of MAX 5** lesser-known books, used only to top up if
   there aren't enough famous candidates to hit `target`. Never pad
   more than 5 below the floor — better to return fewer picks than
   to ship obscure books just to hit a round number.

The response includes the breakdown:

```json
{
  "target": 30, "buffer": 5, "famous_floor": 0.8,
  "famous_available": 27, "famous_picked": 27,
  "buffer_picked": 3, "total_picked": 30,
  "lowest_score_in_picks": 0.71,
  "below_floor_count": 18,
  "picks": [<inventory entry>, ...]
}
```

If `famous_picked` is well below `target`, **say so to the operator**:
the batch genuinely doesn't have 30 famous books and shipping 30 would
mean shipping obscurity. Better to recommend 27 (or whatever
`famous_picked + min(buffer, gap)` is).

After getting the picks, this is where **your literary judgment** comes
in. Walk the list and:

- Read HEAD samples (~2K chars) of the top picks using your Read tool
  — the only LLM-side cost in curate.
- Group by theme / era / genre if you spot a coherent collection
  ("8 Gothic novels → bundle as a Gothic Collection," "5 Russian
  classics → underrepresented on the platform").
- Flag bad fits to drop entirely: scanned PDFs, multi-column academic
  books, very short or very long files, books in languages the platform
  doesn't yet support.

Surface a "trend" recommendation back to the operator: which genres
dominate this batch, what's missing vs. what's already on the platform
(use `GET /api/inventory` to see what's already done).

### Note on "already in the app"

The inventory only knows about books that flowed through dispose
(imported from main, or freshly converted here). If books were
published directly through the main project AFTER day-one import,
they won't be in our inventory until you refresh:

```
POST /api/import-from-main
```

Run this before triage if the operator says "there's stuff in
production you haven't seen yet". The import is idempotent — it
won't re-copy what's already present, just adds new entries.

### Step 2.5 — Web-verify demand + copyright (use WebSearch / WebFetch)

The triage score is a heuristic — Gutenberg low-ID + length + genre
keyword. It tells you which books *probably* matter, not which books
*actually* trend right now or are *actually* safe to redistribute. Use
your **WebSearch** and **WebFetch** tools to ground those guesses
before recommending the final set.

For each book in `picks` (top 20–30 is plenty — don't bother for the
buffer tier), do a light-weight verification pass:

#### 1. Real demand signal — is this still being read?

Three quick checks per book, in priority order:

- **Project Gutenberg "Top 100 last 30 days"** — the most current
  signal for free PD books.
  - `WebFetch("https://www.gutenberg.org/browse/scores/top", "Find the 'Top 100 EBooks last 30 days' list and report the position of the book if present")`
  - A book in the live top-100 is genuinely in demand right now.
- **Wikipedia presence + page-view recency.**
  - `WebSearch("<title> <author> wikipedia")` — confirm a Wikipedia
    article exists; if it does, the book has cultural weight.
  - Optional: pull the page's view count via the Wikipedia REST API
    (`https://wikimedia.org/api/rest_v1/metrics/pageviews/per-article/...`)
    if you want a numeric signal.
- **Goodreads ratings count.**
  - `WebSearch("<title> <author> goodreads")` — look at the result
    snippet for "X ratings" / "Y reviews". >100K ratings = enduringly
    popular; >1M = pillar of the canon.

#### 2. Copyright / public-domain check

Three layers, from cheapest to strongest:

- **Gutenberg ID prefix** — if the source filename starts with a
  Gutenberg digit prefix (e.g. `00174_…`) the book is **already
  verified public domain by Project Gutenberg**. No further check
  needed.
- **Author's death year + 70 years.** Public-domain status in most
  jurisdictions is `(year of author's death) + 70 years <= current year`.
  Wikipedia gives the death year reliably.
  `WebSearch("<author> death year")` is enough.
- **Cross-check Gutenberg's catalog** if the file came from elsewhere
  (a stray PDF): `WebFetch("https://www.gutenberg.org/ebooks/search/?query=<title>+<author>", "Is this book in Gutenberg's catalog? If yes, return the ebook ID.")`.
  Presence in Gutenberg = PD for redistribution.

If a book fails the PD check (still in copyright, author alive or
died <50 years ago, no Gutenberg listing): **drop it from the picks**
and note `public_domain: false` in the inventory. Don't recommend
it. Don't convert it. The operator should never accidentally ship
a book they don't have rights to.

#### 3. Persist the signals to inventory

Write what you learned back to `storage/inventory.json` via
`inventory.update_entry(slug, demand=...)`. The shape:

```json
{
  "demand": {
    "checked_at": "2026-05-13T04:30:00Z",
    "gutenberg_top_30day": {"present": true, "rank": 47},
    "wikipedia": {"present": true, "url": "https://en.wikipedia.org/wiki/..."},
    "goodreads": {"ratings_count": 4_800_000, "avg_rating": 4.27},
    "public_domain": true,
    "pd_source": "gutenberg-id-prefix",
    "notes": "Live in Gutenberg top-100 — sustained demand."
  }
}
```

Future sessions skip the web check if `demand.checked_at` is recent
(<30 days). Re-check after a month to catch shifts in current demand.

#### 4. Suggest books NOT yet in the folder

If a great book keeps showing up in your web searches but **isn't**
in `data/` and isn't in the inventory, surface it as a recommendation
to the operator at the end of curate:

> "Project Gutenberg's current top-100 includes 7 books not in your
> data drop: *Anna Karenina* (PG #1399), *Heart of Darkness* (#219),
> *The Brothers Karamazov* (#28054 — actually you HAVE this, ignore),
> *Pride and Prejudice* (already in library, ignore), …. Want me to
> fetch them so they enter the next conversion cycle?"

If the operator says yes, the **operator fetches them** into `data/`
(via their browser or `curl https://www.gutenberg.org/ebooks/<id>...`).
You don't fetch them yourself — the studio doesn't have outbound
internet for that, and Gutenberg's UTF-8 HTML downloads behind a CDN
need a real browser session anyway. Just give the operator a tidy
list with Gutenberg IDs + direct download URLs.

#### 5. When to skip the web check

- Already-checked recently (`demand.checked_at < 30 days ago`).
- Operator says "skip web" — e.g. they're behind a firewall, or
  doing a fast triage pass.
- Books in the buffer tier (below famous floor) — not worth the
  verification cost since they're filler anyway.

### Step 3 — Convert (the heavy work, fully automated)

For each picked book, walk phases 0 → 11 from §5 **including
Phase 10.5 (Generate all images, server-side)**. No human is
required at any point during conversion — Claude runs cleaning,
chunking, prompts, AND image generation in one continuous flow.

After Phase 10.5 flips `manifest.ready_for_runtime = true`, also
update the inventory entry:

```python
inventory.mark_phase(slug, "<phase>")  # per phase
inventory.mark_status(slug, "ready")    # after Phase 10.5
```

The inventory is now the resilience contract: if the run is
interrupted (Ctrl-C mid-batch, network blip during Azure calls),
re-running checks `inventory.is_done()` per source file and skips
anything already at status `ready` / `deployed` / `imported`. The
per-image PNGs on disk are themselves the resume signal — a re-run
of Phase 10.5 only generates the ones still missing.

### Step 4 — Visual review (optional, manual)

After conversion the operator opens `http://localhost:8765/` and
spot-checks the books. Every image is already on disk; the reader
just sees them.

If a specific scene's image looks wrong, they can:
- Click **Regenerate** on the scene card (same endpoint as initial
  generate; backs up the old PNG, calls Azure again)
- Or ask Claude to rewrite the prompt JSON and regenerate (better
  for systemic issues like "Alice's costume is wrong in every scene")

The "Generate all N images" button on the book detail page is now
a **manual retry / catch-up** path — it only does work for any
PNGs that didn't land during Phase 10.5 (typical reason: Azure
content-policy that all 5 rephrase strategies couldn't soften).

### Step 5 — Deploy (push to the VM)

When a book looks right:

```
POST /api/books/<slug>/deploy   (or ./deploy.sh <slug>)
```

SFTPs `storage/books/<slug>/` to
`azureuser@20.219.16.30:/home/azureuser/inkspace/storage/books/<slug>/`.
After success, `inventory.mark_status(slug, "deployed")` so a future
run sees this book as truly done.

### Idempotency contract — what "no repeated work" means

The inventory is keyed by **source file sha256**. Drop the same PDF
twice under different filenames → same entry → same slug → no
re-triage, no re-convert. Drop a slightly different file (e.g. a
re-OCRed PDF) → different hash → fresh entry → fresh work.

Statuses progress monotonically:
`discovered → triaged → ready → deployed`

A book in `ready` is fully prepped but not pushed to the VM yet. A
book in `deployed` is live. Going backward (re-doing) requires
explicit operator intent — the system never silently re-does work.

### Pre-existing artifacts (imported from the main project)

11 books from `/Users/vijayshankar/Desktop/write/backend/test_model`
were imported on day one — Alice, Frankenstein, Dracula, Jekyll &
Hyde, Pride and Prejudice, Frederick Douglass, Sherlock Holmes, The
Great Gatsby, To Kill a Mockingbird, Siva Puranam, and Jekyll. They
are in the **legacy artifact format** (briefs/, deeps/, chunks/, plus
generated PNGs in images/). They're already valuable:
- The PNGs cost real money to generate — don't redo them.
- The text artifacts (briefs/deeps) are reusable as-is for the new
  Quill Delta format with a free translation pass.

The studio lists them in the library with `legacy_format: true`. When
the operator (or you, in conversation) wants to fully read them in
the new format, you do a one-time translation phase: read the legacy
briefs+deeps+chunks, emit `sections/<chunk_id>.delta.json` +
`poster.json` + `cover.json` (status: ready, image_path: cover_image.png).
No API calls, just JSON munging.

To re-import (if the main project gains new books):

```
POST /api/import-from-main
```

It's idempotent — already-present books skip.

---

## 16. The one-line summary

Take a raw book. Clean it like an editor. Direct it like an art
director. Lay it out like a typesetter. Save it as ready-made files.
Let the reader pick which scenes come to life. Deploy when ready —
the Flutter app picks up the rest.
