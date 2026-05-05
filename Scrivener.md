# Scrivener → InkSpaceX

A plan to bring a Scrivener-class writing experience into InkSpaceX **without** taking on Scrivener's two worst features: the Compile dialog and its discoverability problem. Final publishing stays on the existing InkSpaceX flow (book + chapters as Quill Delta), so structure-during-writing and structure-for-readers are the same artifact.

Source for the essentials kit: Lauren Kay's "How to Use Scrivener (2024)" tutorial, which teaches Scrivener as a minimal 15-feature MVP and admits most of the rest is "hidden everywhere and I don't use it."

---

## 1. Feature comparison

| # | Scrivener feature | InkSpaceX today | Status | Why ours is better — or what we need |
|---|---|---|---|---|
| 1 | **Cloud backup** (Dropbox folder hack, no autosave) | Native FastAPI/Postgres/S3 backend with `sync_service` + `offline` service; autosave by default | ✅ stronger | Zero setup. No "save to a Dropbox folder" ritual. Works on web (Scrivener has no web). Real conflict resolution, not last-write-wins on a sync folder. |
| 2 | **Hierarchy: Acts → Chapters → Scenes** | `WritingModel.sections` — flat list of chapters (one level) | ⚠️ partial | Need optional nesting: `Section.parentId`. (a) Optional Act folders above chapters, (b) optional Scenes inside chapters. Flat stays default; nesting opt-in. |
| 3 | **Three views: Draft / Corkboard / Outline** (`⌘1/2/3`) | Drafting view only (`writing_page`); no corkboard, no outline | ❌ missing | Easy add: corkboard reads `section.title + synopsis`; outline reads same plus metadata. Top-level segmented control, not a buried menu. |
| 4 | **Synopsis per scene** | No dedicated synopsis field | ❌ missing | Add `SectionModel.synopsis: String`. Drives both corkboard and outline rows. Trivial migration. |
| 5 | **Project-default formatting** | Editor renders sections with shared default style | ⚠️ partial | We don't need write-time vs publish-time split because publish renders the same Quill Delta directly. Win by deletion: zero compile dialog, zero "did my italics survive." |
| 6 | **Notes pane per scene** ("graveyard for cut text") | `EditorAnnotation` is anchored + threaded — not a free-form per-section scratchpad | ⚠️ partial | Add `SectionModel.notes: String`. Distinct from anchored annotations. Side panel toggle. |
| 7 | **Snapshots** | `SectionVersionModel` + `version_history_widgets.dart` already exist | ✅ on par | Plus auto-snapshot before AI rewrites (slash menu / grow-shrink). Scrivener has no AI, can't do this. |
| 8 | **Color-coded binder labels** (status / POV / subplot) | None | ❌ missing | Add `SectionModel.labelColor + WritingModel.labelMeaning` (user-defined: status / POV / subplot / mood). One-click on the binder row. Background-color-in-binder mode by default. |
| 9 | **Custom scene icons** | None | ❌ missing — but skip | Color labels already cover "visual marker." Skip icons; not worth the picker UI. |
| 10 | **Project Targets** (manuscript total + session) | `daily_goal_service` (just added; daily only) | ⚠️ partial | Extend: `WritingModel.targetWordCount + targetDeadline`. Auto-distribute to daily goal. Progress bars on book detail page. |
| 11 | **Writing History** (words/day, words/month) | Inside `daily_goal_service` skeleton; not exposed as a view | ⚠️ partial | Plumbing exists — needs a chart. `reading_statistics_page` is the design template, flipped to authoring. |
| 12 | **Keywords per scene + search** | `tag_feed_page` exists but tags are at writing level, not section level | ❌ at section granularity | Add `SectionModel.keywords: List<String>`. "Show all scenes with character Daisy" becomes real authoring. We can layer reading-retention on top — Scrivener cannot. |
| 13 | **Name generator** (gender/country/alliteration) | `gemini_service` already wired | ✅ stronger | "Generate 5 alliterative female names from coastal Maine, last name K" → AI delivers richer results, no constraints UI. Free win. |
| 14 | **Two-pane view** | Single-pane | ❌ missing | Web/desktop: split editor with sibling panel. Mobile: skip (not enough space). One layout flag. |
| 15 | **Compile** (section types → layouts → PDF/DOCX) | `publish_page` ships book + chapters direct to readers | ✅ massively stronger — by deletion | The binder structure IS the publish payload. Lauren spent 3.5 min wrestling section-types in the tutorial; our writers spend zero. Plus our output reaches an audience, not a `.pdf` that needs uploading elsewhere. |

### Score
- **On par or stronger:** 4 / 15 (1, 7, 13, 15)
- **Partial — small adds:** 5 / 15 (2, 5, 6, 10, 11)
- **Missing — clean adds:** 5 / 15 (3, 4, 8, 12, 14)
- **Missing but skip:** 1 / 15 (9)

### What we already have that Scrivener does not
- Web app (Scrivener has none)
- Native cloud sync (Scrivener uses a Dropbox folder hack)
- Mobile-first editor — touch toolbar, slash menu, ruler bar
- AI: rewrite, expand, shrink, slash actions (Gemini)
- Threaded anchored comments (`EditorAnnotation`)
- Built-in readers + `reading_progress`
- Per-chapter retention analytics flowing back to the author (data plane exists)
- Social: follow / feed / chat / notifications
- Subscription / paywall infrastructure
- Canvas mode (`canvas_element_model`) for visual planning
- **Direct publish — structure = output, no compile dialog**
- Free tier (Scrivener is $60)

---

## 2. Build plan — Scrivener-class writing UX inside InkSpaceX

Final publish stays unchanged: `publish_page` ships the book + chapters whose Quill Delta `content` is already authoritative. Everything below is **drafting-side** UX. Nothing changes the published artifact's shape.

### 2.1 Data model deltas

All additive. No backwards-compatibility shims needed; defaults make missing fields harmless.

```dart
// lib/models/section_model.dart
class SectionModel {
  String id;
  String title;
  String content;          // Quill Delta JSON — unchanged, source of truth
  String canvasData;
  bool isSynced;
  DateTime createdAt;
  DateTime updatedAt;

  // NEW
  String? parentId;        // null = top-level chapter; non-null = scene under parent
  int order;               // explicit ordering within parent
  SectionKind kind;        // chapter | scene | act | folder | research | trash
  String synopsis;         // short text, drives corkboard + outline
  String notes;            // free-form scratchpad; "graveyard for cut text"
  int? labelColor;         // ARGB int, null = unlabeled
  List<String> keywords;   // characters, themes, POV — user-defined
  bool includeInPublish;   // true for chapter/scene under Manuscript; false for research/trash
}

enum SectionKind { act, chapter, scene, folder, research, trash }
```

```dart
// lib/models/writing_model.dart
class WritingModel {
  // existing fields unchanged
  // NEW
  int? targetWordCount;        // manuscript target
  DateTime? targetDeadline;    // optional deadline; daily goal auto-distributes
  String labelMeaning;         // "status" | "pov" | "subplot" | "mood" | custom
  Map<int, String> labelNames; // labelColor → human name ("Done", "Drafting", "Daisy POV")
}
```

Backend mirror: extend the section table with these columns, all nullable / defaulted. Migration is purely additive.

### 2.2 The binder — left rail

A tree widget over `WritingModel.sections`, grouped by `parentId` and ordered by `order`. Three top-level folders auto-created on new project:

- **Manuscript** — `includeInPublish = true` for descendants. This is what `publish_page` ships.
- **Research** — `includeInPublish = false`. Free-form notes, links, images.
- **Trash** — soft-deleted sections; recoverable.

Drag-to-reorder, drag-between-folders, multi-select. Right-click (or long-press on mobile) → label color, kind, snapshot, duplicate, move to trash.

Files to add / touch:
- `lib/ui/pages/editor_page_entry/writing_page/binder_pane.dart` — new
- `lib/ui/pages/editor_page_entry/editor_page_entry.dart` — wire binder as left rail on web/desktop; bottom-sheet on mobile
- `lib/services/sync/` — propagate `parentId` / `order` changes

### 2.3 Three views — `⌘1 / ⌘2 / ⌘3`

A segmented control at the top of the editor surface. Same selection in the binder drives all three:

1. **Draft** (`⌘1`) — current `writing_page`, unchanged.
2. **Cards** (`⌘2`) — corkboard. Each visible section is a card showing `title` + `synopsis`, tinted by `labelColor`. Drag-to-reorder rewrites `order`.
3. **Outline** (`⌘3`) — table with columns: title · synopsis · wordcount · label · keywords · status. Sortable. Inline-editable for synopsis, keywords, label.

Files:
- `lib/ui/pages/editor_page_entry/writing_page/views/cards_view.dart`
- `lib/ui/pages/editor_page_entry/writing_page/views/outline_view.dart`
- `lib/ui/pages/editor_page_entry/writing_page/view_switcher.dart`

### 2.4 Synopsis + Notes panel

Right-rail panel on the editor, two stacked sections:
- **Synopsis** — single-line / short multiline; the same field rendered on cards.
- **Notes** — free-form Quill (or plain text) area, scoped to the section. Cut-text graveyard.

Existing `annotations_panel.dart` stays — anchored threaded comments. Notes are distinct (not anchored, not threaded).

### 2.5 Labels with semantic flexibility

User picks what their colors mean per project (`WritingModel.labelMeaning`):
- **Status** — Done / Drafting / Needs Edit / Cut
- **POV** — Nick / Daisy / Gatsby
- **Subplot** — Romance / Mystery / Theme
- **Custom** — user names each color

One-click swatch on every binder row. Background-color in binder by default (tutorial-validated preferred mode). Filter the binder by label.

### 2.6 Project Targets + Writing History

Extend `daily_goal_service.dart`:
- Read `WritingModel.targetWordCount` and `targetDeadline`.
- Compute remaining words ÷ remaining days → today's recommended goal.
- Persist daily wordcount deltas (already partially there).

Surface:
- Target progress ring on book detail page.
- "Writing History" tab — bar chart, words per day / week / month. Mirror `reading_statistics_page` styling, flip the data source.

### 2.7 Keywords + scene search

- Add a keyword chip row in the right-rail panel.
- Auto-complete from existing keywords in this writing.
- Search bar in binder: `keyword:Daisy` filters visible nodes.
- Bonus (post-MVP): join with `reading_progress` to surface "scenes tagged Daisy retain 12% better" — a feature Scrivener structurally cannot offer.

### 2.8 AI-powered name generator

Add to `slash_menu.dart` and to a small "Tools" sheet:
- Prompt template via `gemini_service`: gender, country/origin, era, alliteration, surname constraint, count.
- Returns 5–10 suggestions; click to copy or insert.

Replaces Scrivener's hardcoded list with something far richer for zero new UI surface.

### 2.9 Two-pane view (web + desktop)

A split-screen toggle on the editor toolbar. Each pane is an independent section selection over the same binder. Mobile: hidden (not enough space).

### 2.10 Snapshots (mostly done)

- `SectionVersionModel` exists; `version_history_widgets.dart` exists.
- Add: **automatic snapshot before AI rewrite** (slash menu, grow/shrink button) — single line in the AI service hook.
- Add: snapshot diff toggle to use the existing `flutter_quill` Delta diff.

### 2.11 Publish — unchanged

`publish_page` already ships book + chapters. Two small filter rules so the binder doesn't leak into readers:

- Only sections under **Manuscript** (`includeInPublish = true`) are sent.
- Sections in **Research** and **Trash** are skipped.
- `synopsis`, `notes`, `keywords`, `labelColor` are author-side only — never serialized into the published payload.

The reader still sees: book cover → chapter list → chapter content (Quill Delta rendered). Identical to today.

---

## 3. Phasing

### Phase A — Structure foundation (1 release)
1. Migration: add `parentId`, `order`, `kind`, `synopsis`, `notes`, `labelColor`, `keywords`, `includeInPublish` to `SectionModel` + DB.
2. Auto-create Manuscript / Research / Trash folders on new + existing projects.
3. Binder pane on web/desktop; bottom-sheet on mobile.
4. Drag-to-reorder + drag-between-folders.
5. Publish filter: `includeInPublish = true` only.

### Phase B — Three views (1 release)
1. View switcher with `⌘1/2/3`.
2. Cards view (corkboard).
3. Outline view (table).
4. Synopsis + Notes right-rail panel.

### Phase C — Metadata & targets (1 release)
1. Color labels + `labelMeaning` setting per project.
2. Filter binder by label / keyword.
3. `WritingModel.targetWordCount + targetDeadline`.
4. Writing History chart.

### Phase D — Polish & differentiators (1 release)
1. AI name generator in slash menu.
2. Two-pane editor (web/desktop).
3. Auto-snapshot before AI rewrite.
4. Reading-retention overlay on outline view (per-section drop-off %).

### Skip permanently
- Custom scene icons (color labels suffice).
- Compile dialog (publish replaces it).
- Section types / section layouts UI (irrelevant when output structure = input structure).

---

## 4. Invariant — final publish remains InkSpaceX-native

Whatever the writer does in the binder — nesting, labels, keywords, synopses, notes, snapshots — the **published artifact is exactly what we ship today**: a `WritingModel` with a list of `SectionModel.content` Quill Deltas. The binder is authoring scaffolding; the Quill Delta is the product.

This is the design that makes us strictly better than Scrivener: structure during writing **without** a translation layer to publishing. No compile, no export, no "did my formatting survive." The binder is the book, before and after publication.
