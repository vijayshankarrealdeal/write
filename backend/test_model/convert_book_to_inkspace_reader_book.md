# Convert Book to Inkspace Reader Book — Claude Desktop Playbook

You (Claude Sonnet 4.6, running in Claude Desktop) are the **mastermind**
for turning N raw books — PDFs or Project Gutenberg HTML — into reader-
ready content for the **Inkspace** app.

**The deal: you prepare everything ready-made on disk.** Cleaned
markdown, briefs, deeps, image prompts, character bibles, poster copy,
Quill Deltas — all of it lands on disk, finished, before any reader
opens the book.

**OpenAI has exactly one job, and it only runs on-demand:** when the
reader opens `index.html`, picks a book, and clicks "Generate image"
on a scene card, the backend calls OpenAI with the prompt you prepared
and saves the PNG. If generation fails, the backend rephrases the
prompt and retries. **No image is generated until a reader asks for
it.** No batch image runs. No background prefetch.

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
| **Image pixel generation** | **OpenAI**, called by backend | **runtime, on reader click** |
| **Prompt rephrase on failure** | Backend (deterministic) | runtime, on retry |

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
- OpenAI calls (embeddings, images) do **not** count against this
  budget — they're a separate provider.

For book N parallelism: with 10 in-flight calls, processing 10 books at
once means each book gets ~1 in-flight call at a time. That's fine —
the bottleneck is wallclock per chunk, not per book. Saturate the 10
slots however the queue fills them.

---

## 5. Pipeline phases — what to do for each book

The phases mirror what `book_ingest/pipeline.py` does today. You are
replacing the LLM bits; the file layout and the resilience contract
stay identical.

### Phase 0 — Load (free)

Input: a path to `.pdf`, `.html`, or `.htm`.

- For PDF: extract text page by page (PyMuPDF via `pdf_loader.py` —
  invoke the existing function, don't reinvent).
- For HTML (Project Gutenberg): use `html_loader.py` — it pulls the
  `<meta>` title/author/subjects and converts the body to clean
  markdown.

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

Use the existing `chunker.py` — it already encodes the heuristics
above.

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

**Read the existing `cleaner.py` system prompt** — its rules are
authoritative. You are executing the same contract Claude Desktop, not
a separate model.

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
  "prompt": "<the FINAL composed prompt — ready to call OpenAI with>",
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

**`status: "pending"`** is the signal to `index.html` that the PNG
hasn't been generated yet. Once the reader clicks "Generate image"
and the backend produces the PNG, the backend flips status to
`"ready"` and adds an `image_path` field.

**No PNG is produced in this phase.** You write prompts only.

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

Compose `storage/books/<slug>/manifest.json` with everything:

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
  "ready_for_runtime": true
}
```

`ready_for_runtime: true` is the signal that `index.html` can open
this book and start offering image-generation buttons. The studio
server uses this to filter which books appear in the library.

### Phase 11 — Bundle (you, optional)

Zip everything under `storage/books/<slug>/` into `bundle.zip` —
manifest, cleaned md, briefs, deeps, deltas, scene/character/cover
prompt JSONs. **No PNGs yet** — they don't exist at prep time. A
later `restore_bundle.py` can replay your text artifacts onto a
fresh disk; the reader then re-triggers image generation on the
restored host.

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
   - Call OpenAI's image endpoint with `prompt` + `negative` +
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

When OpenAI rejects or fails on a prompt, the backend doesn't give
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

Use the existing `image_softener.py` rules as the basis for attempt
2's deterministic rewrites. If a book consistently fails on a
specific character, that's a signal to you — go back and rewrite
the character's `appearance` in the bible so it doesn't trip the
filter.

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

Everything lives under `backend/test_model/storage/books/<slug>/`.
After prep finishes (before any reader opens the book):

```
manifest.json                      # title, author, slug, scout, poster, phases_done, ready_for_runtime: true
pages/0001.json                    # raw extracted text, per page (kept for audit)
cleaned/<chunk_id>.md              # your cleaned markdown
briefs/<chunk_id>.json             # one ChunkBrief per chunk
deeps/<chunk_id>.json              # one ChunkDeep per top-importance chunk
chunks/<chunk_id>.json             # composite {chunk, brief, deep?, scene_ids[]}
sections/<chunk_id>.delta.json     # FINAL Quill Delta — what index.html renders
plan.json                          # picked scenes, scored
highlights.json                    # flat list of all highlight spans
poster.json                        # back-cover copy, genres, tags
cover.json                         # cover prompt + title_overlay (status: pending)
images/<scene_id>.json             # FINAL scene prompt + characters_present + status: pending
characters/<name_slug>.json        # {name, appearance, bio, prompt, status: pending}
bundle.zip                         # ready-made archive (text only — no PNGs yet)
```

After readers start clicking "Generate image" at runtime, the
backend adds PNGs alongside the JSONs:

```
images/<scene_id>.png              # appears after first successful click
images/<scene_id>.json             # status flips: pending → ready, image_path + generated_at added,
                                   # attempts: [...] log for failures
characters/<name_slug>.png         # appears after first click on cast strip OR
                                   # implicitly when a scene needs it as a reference
cover.png                          # appears after cover-click + typography overlay step
```

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

When you hit a transient OpenAI error (429, 5xx, timeout): retry with
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
   call OpenAI with.

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

For exact field names and defaults, **always** consult
`book_ingest/schemas.py` and `book_ingest/scout.py` rather than relying
on this document. If schemas drift, schemas win — update this doc.

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
- Don't use OpenAI for any text task. It's pixels only — and only when
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

### 12.1 Covers have no title typography on them (Netflix-style)

**What's odd:** the generated covers are gorgeous painterly scenes —
characters, setting, mood, palette all locked in — but they have **no
book title rendered on the artwork itself**. The title appears only as
a text label *below* the card (see the "Continue reading" row:
*To Kill a Mockingbird*, *Pride and Prejudice*, *The Great Gatsby*,
*The Strange Case of Dr. Jekyll and Mr. Hyde* are all bare scene
paintings with their titles set in the app's UI label, not in the
artwork).

Netflix posters, by contrast, almost always bake the title into the
artwork — custom typography integrated into the composition, sized
for thumbnail recognition. That's why a Netflix thumbnail reads
instantly even when the row is scrolling fast. Our cards make the
reader's eye jump from artwork → label → back to artwork.

**Why it happens today:** every image prompt — cover included —
appends the negative tokens `no text, no logos, no signature, no
watermark`. That's correct for *interior scene illustrations* (where
hallucinated lorem-ipsum on the page would ruin the reading
experience), but wrong for the **cover**, where typography is the
whole point.

**Two ways to fix it — pick one:**

1. **Composite the title in post.** Image model produces the painting
   (still with negative-text tokens); a separate typography pass
   overlays the title using Pillow or SVG. Pros: deterministic font
   choice, free variants (different sizes, different positions,
   different language editions), no spelling errors. Cons: the title
   sits *on top of* the artwork rather than being interlocked with
   it the way a real Netflix poster is designed.

2. **Let the image model render the title.** For the cover prompt
   only, drop the `no text` token and explicitly instruct: "title
   '<TITLE>' in <font genre> serif, integrated into the composition.
   Author byline '<AUTHOR>' set smaller below." Pros: organic, looks
   designed. Cons: image models still misspell titles regularly;
   you'd need a verify-and-retry loop, and the model — not you —
   picks the font.

**Recommendation:** start with option 1 because it ships this week
and the typography is fully deterministic. Add option 2 as an
optional "stylised" variant later for books where the genre supports
hand-lettered titles (gothic, fantasy, vintage).

**Where it would live in the pipeline:** a new sub-phase between
Phase 10 (Poster) and the sync step. The poster phase has already
chosen `cover_scene` and the base palette; the new "cover
typography" pass reads `manifest.title` + `manifest.subtitle` +
`manifest.author` + `scout.suggested_style` and either composites or
re-prompts.

**Also fix the byline.** The same Netflix gap applies to the author
name — a small "HARPER LEE" / "JANE AUSTEN" set under the title
would complete the poster look. That comes for free with option 1.

---

## 13. Backend code — what stays, what goes

Now that Claude Desktop owns the entire ingest pipeline, the backend
shrinks. Here's the proposed cut. **Confirm before deleting** — none
of this is destroyed without explicit approval.

### Keep (image-gen runtime + studio + minimal helpers)

| File | Why |
|---|---|
| `studio/server.py` | The runtime. Trim it to: serve static, serve artifacts, generate image, sync to DB. |
| `studio/static/index.html` | The reader UI. Add "Generate image" buttons on 404 placeholders. |
| `book_ingest/image_gen.py` | The OpenAI call. Backend's one real job. |
| `book_ingest/image_softener.py` | Deterministic prompt rewrites for the retry loop. |
| `book_ingest/retry.py` | Exponential backoff for transient OpenAI errors. |
| `book_ingest/persist.py` | Read-only helpers — load JSON, read paths, atomic writes for the new PNGs. |
| `book_ingest/schemas.py` | So the server can deserialize what Claude wrote. |
| `book_ingest/config.py` | Image API keys + endpoints. Other env vars can be trimmed. |
| `book_ingest/delta.py` | Only if the server still needs to re-render deltas; if Claude writes finished deltas, this can also go. Recheck. |
| `book_ingest/db_publish.py` | Sync-to-DB still runs server-side. |
| `sync_to_db.py` | The DB+MinIO upload entrypoint, called from `index.html`. |
| `restore_bundle.py` | Insurance — replay an old book's text artifacts. |
| `book_ingest/bundler.py` | Companion to `restore_bundle.py`. |

### Delete (Claude does this now)

| File | Replaced by |
|---|---|
| `book_ingest/pipeline.py` | The phases in this playbook |
| `book_ingest/cleaner.py` + agent prompt | Phase 2 of this playbook |
| `book_ingest/chunker.py` | Phase 1 (you do the heuristics) |
| `book_ingest/map_agent.py` + `agents.py` | Phase 4 |
| `book_ingest/reduce_agent.py` | Phase 5 |
| `book_ingest/scout.py` | Phase 3 |
| `book_ingest/character_sheets.py` | Phase 7 (you write the prompts; backend generates on click) |
| `book_ingest/poster.py` | Phase 8 (you write the copy directly) |
| `book_ingest/embeddings.py` | Removed entirely — no scene-search UX in scope |
| `book_ingest/image_planner.py` | Phase 6 (you sort + take top-K) |
| `book_ingest/title_cleaner.py` | You clean the title yourself |
| `book_ingest/boilerplate.py` | Phase 2 rules cover boilerplate |
| `book_ingest/known_authors.py` | You resolve authors yourself |
| `book_ingest/html_loader.py` | Phase 0 — you read HTML directly |
| `book_ingest/pdf_loader.py` | Phase 0 — you read PDF via PyMuPDF directly when needed |
| `book_ingest/md_to_delta.py` | Phase 9 — you build deltas directly |
| `book_ingest/app_taxonomy.py` | Phase 8 — you pick genres + tags directly |
| `book_ingest/map_agent.py` | Phase 4 |
| `ingest_book.py` | Claude Desktop is the entrypoint |
| `batch_ingest.py` | Same |
| `regenerate_image.py` | Replaced by the "Generate image" button + rephrase loop |
| `repair_books.py` | One-off scripts — keep only if you still need them, otherwise drop |
| `preview_html.py` | Dev-only |
| `package_book.sh` | Replaced by `bundler.py` |
| `smoke_test.sh` | Pipeline that no longer exists |
| `plan.md` | This playbook supersedes it; keep as historical reference or drop |

### After the cut, the backend tree looks like

```
backend/test_model/
  studio/
    server.py            # slim FastAPI: serve artifacts + generate image
    static/index.html    # reader UI with "Generate image" buttons
  book_ingest/
    image_gen.py         # OpenAI call
    image_softener.py    # deterministic prompt rewrites for retry
    retry.py             # exponential backoff
    persist.py           # read artifacts, atomic write PNGs
    schemas.py           # pydantic types for the JSONs Claude writes
    config.py            # image API keys
    db_publish.py        # used by sync
    bundler.py           # zip artifacts
  sync_to_db.py          # button-triggered DB+MinIO upload
  restore_bundle.py      # insurance replay
  storage/books/<slug>/  # everything Claude wrote
  convert_book_to_inkspace_reader_book.md  # this playbook
```

That's ~10 Python files instead of ~25. The diff is mostly
**deletion**, no rewrites — the existing image-gen and studio
endpoints already do the right thing, they just become the *only*
thing.

---

## 14. The one-line summary

Take a raw book. Clean it like an editor. Direct it like an art
director. Lay it out like a typesetter. Save it as ready-made files.
Let the reader pick which scenes come to life.
