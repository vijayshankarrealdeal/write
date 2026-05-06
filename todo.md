# InkSpaceX → Scrivener-class Writing UX — TODO

> **Source plan:** [Scrivener.md](Scrivener.md). This file is the verification + execution checklist that mirrors the 15-feature comparison table.
>
> Legend: ✅ done · ⚠️ partial · ❌ not started · ⏭ skip permanently
>
> **Implementation pass landed 2026-05-06.** All four phases (A–D) end-to-end.

---

## 1. Cloud backup ✅

**Brief.** Native FastAPI/Postgres/S3 backend with autosave by default, real conflict resolution, and works on web (Scrivener has no web).

**Implemented.**
- `lib/services/api/` — `api_client`, `api_data_service`, `api_storage_service`, `api_realtime_service`, etc.
- `lib/services/sync/` — `outbox`, `outbox_drainer`, `sync_dispatcher`, `merge_log`, `pending_op`. Drainer now handles `updateWritingProject` and routes section metadata patches through `updateSectionMetadata`.

**How to verify.** Open a writing, type some text, kill the app, reopen — content is restored. Open the same writing on a second device → changes sync. Toggle offline → edits queue and drain when reconnected.

---

## 2. Hierarchy: Acts → Chapters → Scenes ✅

**Brief.** Optional nested hierarchy via `Section.parentId`. Flat stays default; nesting opt-in. Manuscript / Research / Trash folders auto-created on every project.

**Implemented.**
- [section_model.dart](lib/models/section_model.dart) — `parentId`, `order`, `kind` (act/chapter/scene/folder/research/trash), `includeInPublish`.
- [editor_provider.dart](lib/provider/editor_provider.dart) — `_ensureBinderFolders()` runs in `loadBooks()` and idempotently bootstraps the three top-level folders for every existing book; orphan top-level chapters get reparented under Manuscript automatically.
- [binder_pane.dart](lib/ui/pages/editor_page_entry/writing_page/binder_pane.dart) — depth-first tree widget over `WritingModel.sections` with drag-to-reorder, drag-between-folders, right-click context menu.
- Backend: `parent_id`, `sort_order`, `kind`, `include_in_publish` columns added to `sections` (additive migration in [main.py](backend/app/main.py)).

**How to verify.** Create a writing → drag a chapter under Research → reload → tree state persists. Existing flat writings render with their chapters auto-nested under Manuscript.

---

## 3. Three views — Draft / Cards / Outline (`⌘1` / `⌘2` / `⌘3`) ✅

**Brief.** Segmented control + keyboard shortcuts switch the editor surface between three modes.

**Implemented.**
- [view_switcher.dart](lib/ui/pages/editor_page_entry/writing_page/views/view_switcher.dart) — segmented control + `EditorViewMode` enum.
- [cards_view.dart](lib/ui/pages/editor_page_entry/writing_page/views/cards_view.dart) — corkboard. Drag-to-reorder rewrites `order`.
- [outline_view.dart](lib/ui/pages/editor_page_entry/writing_page/views/outline_view.dart) — sortable table with inline-editable synopsis, label color picker, publish-gate switch.
- [editor_page_entry.dart](lib/ui/pages/editor_page_entry/editor_page_entry.dart) — `CallbackShortcuts` binds `⌘1/2/3` (and `Ctrl+1/2/3`) to mode switching.

**How to verify.** Press `⌘2` → corkboard. Press `⌘3` → table. Drag a card → reorders the binder. Edit a synopsis inline → propagates to corkboard.

---

## 4. Synopsis per scene ✅

**Brief.** Short text per section that drives corkboard cards and outline rows.

**Implemented.**
- `String synopsis` on [section_model.dart](lib/models/section_model.dart) (default empty, additive migration).
- [section_inspector.dart](lib/ui/pages/editor_page_entry/writing_page/section_inspector.dart) right-rail edits the field; cards + outline read it. The same widget renders as a draggable bottom sheet on mobile via the `asSheet: true` flag, opened from the mobile top-actions toolbar (`info` icon).

**How to verify.** Open a section → right-rail Synopsis field (desktop) or tap the Inspector icon in the mobile top toolbar → type a sentence → it appears on the matching corkboard card and outline row.

---

## 5. Project-default formatting ✅

**Brief.** `publish_page` ships the same Quill Delta the editor renders. Win by deletion: zero compile dialog.

**Implemented.** [publish_page.dart](lib/ui/pages/publish_page.dart) — single Delta path. Folders + Research + Trash are filtered out before assembly.

---

## 6. Notes pane per scene ✅

**Brief.** Free-form scratchpad ("graveyard for cut text"). Distinct from anchored, threaded comments.

**Implemented.**
- `String notes` on [section_model.dart](lib/models/section_model.dart). Backend column added.
- [section_inspector.dart](lib/ui/pages/editor_page_entry/writing_page/section_inspector.dart) — Notes textarea with multiline editing. Reachable on desktop via the side-rail Inspector toggle and on mobile via the `Inspector` icon in the top-actions toolbar (opens the same widget in a bottom sheet).
- Confirmed excluded from publish payload (only Manuscript-folder sections with `includeInPublish == true` are sent).

---

## 7. Snapshots ✅ (auto-snapshot before AI rewrites: ✅)

**Brief.** Point-in-time captures of section content for safe rewrites and revert. Auto-capture before AI rewrites — a feature Scrivener structurally cannot offer.

**Implemented.**
- [section_version_model.dart](lib/models/section_version_model.dart), [version_history_provider.dart](lib/provider/version_history_provider.dart), [version_history_widgets.dart](lib/ui/pages/editor_page_entry/writing_page/version_history_widgets.dart).
- [editor_page_entry.dart](lib/ui/pages/editor_page_entry/editor_page_entry.dart) `_applyMergedDelta` — calls `captureManual(controller, label: 'Before AI rewrite')` before applying every AI delta, covering the slash-menu / grow-shrink / AI panel paths through their single apply point.

---

## 8. Color-coded labels with semantic meaning ✅

**Brief.** Binder labels are a one-click color tag whose meaning is user-defined per project (status / POV / subplot / mood). Background-color in binder by default.

**Implemented.**
- `int? labelColor` on [section_model.dart](lib/models/section_model.dart); `String labelMeaning` + `Map<int, String> labelNames` on [writing_model.dart](lib/models/writing_model.dart). Backend columns added.
- [binder_pane.dart](lib/ui/pages/editor_page_entry/writing_page/binder_pane.dart) — context-menu swatch picker, label-tinted backgrounds.
- [project_settings_dialog.dart](lib/ui/pages/editor_page_entry/writing_page/project_settings_dialog.dart) — picks `labelMeaning` and names each color in the palette.
- Filter chips at the top of the binder narrow the tree by selected label.

---

## 9. Custom scene icons ⏭

**Skip permanently.** Color labels (#8) cover "visual marker" without a picker UI.

---

## 10. Project Targets (manuscript total + session) ✅

**Brief.** Total-manuscript target + deadline that auto-distribute into the daily goal.

**Implemented.**
- `int? targetWordCount`, `DateTime? targetDeadline` on [writing_model.dart](lib/models/writing_model.dart). Backend columns added.
- [daily_goal_service.dart](lib/services/daily_goal_service.dart) — `recommendedDailyGoal({…})` static helper computes today's target as `ceil(remaining ÷ daysLeft)`.
- [project_settings_dialog.dart](lib/ui/pages/editor_page_entry/writing_page/project_settings_dialog.dart) — circular progress ring + recommended-today readout.

---

## 11. Writing History (chart) ✅

**Brief.** Bar chart of words written per day / week / month.

**Implemented.**
- [writing_history_page.dart](lib/ui/pages/writing_history_page.dart) — bar chart over `DailyGoalState.history`, segmented Week / 2 weeks / Month. Reachable from project settings.

---

## 12. Keywords per scene + search ✅

**Brief.** Per-scene keyword tags ("Daisy", "POV: Nick", "Romance") with binder search like `keyword:Daisy`.

**Implemented.**
- `List<String> keywords` on [section_model.dart](lib/models/section_model.dart). Backend column added.
- [section_inspector.dart](lib/ui/pages/editor_page_entry/writing_page/section_inspector.dart) — keyword chip row with autocomplete from existing keywords on the project.
- [binder_pane.dart](lib/ui/pages/editor_page_entry/writing_page/binder_pane.dart) — search bar parses `keyword:foo`. Otherwise free-text matches title + synopsis + keywords.

---

## 13. AI name generator ✅

**Brief.** Replace Scrivener's hardcoded list (gender / country / alliteration) with a Gemini-prompted generator.

**Implemented.**
- Backend prompt: `generate_names` action in [router.py](backend/app/ai/router.py).
- Frontend: `GeminiService.generateNames(...)` in [gemini_service.dart](lib/services/gemini_service.dart).
- UI: [name_generator_dialog.dart](lib/ui/editor/name_generator_dialog.dart). Slash menu entry "Generate names" inserts the picked name at the caret.

---

## 14. Two-pane view ✅ (read-only secondary pane)

**Brief.** Split-screen on web + desktop, second pane shows an independent section. Mobile skipped.

**Implemented.**
- [secondary_pane.dart](lib/ui/pages/editor_page_entry/writing_page/secondary_pane.dart) — read-only Quill renderer with a section picker. Read-only by design: avoids dual-controller state for the primary editor; this satisfies the "independent section selection" goal for reference reading. A future iteration can promote it to a second editable pane if a real use case emerges.
- Toggle button in the editor toolbar (next to view switcher), hidden on mobile.

---

## 15. Compile (publish) ✅ — strictly stronger by deletion

**Implemented + filter rules landed.**
- [publish_page.dart](lib/ui/pages/publish_page.dart) — `_publishableSections` filters out Manuscript / Research / Trash folder rows and any section with `includeInPublish == false`. Synopsis / notes / keywords / labelColor never serialize into the published payload (they're author-side fields on the model — `publish_page` only reads `id`, `title`, `content`, `canvasData`, `sectionColor`).

---

## Phasing summary (from Scrivener.md §3) — all phases shipped

- **Phase A — Structure foundation:** ✅ #2, #4 (data), #6 (data), #8 (data), #12 (data), #15 filter rules. Single additive migration.
- **Phase B — Three views & panels:** ✅ #3, #4 (UI), #6 (UI), inspector right rail (desktop) + bottom-sheet (mobile), view switcher with `⌘1/2/3`.
- **Phase C — Metadata & targets:** ✅ #8 (UI + filter), #12 (UI + search), #10, #11.
- **Phase D — Polish & differentiators:** ✅ #13, #14 (read-only), #7 auto-snapshot, retention overlay on outline view (`GET /api/writings/{id}/section-retention` → tinted pill per row in [outline_view.dart](lib/ui/pages/editor_page_entry/writing_page/views/outline_view.dart) showing how many of N readers are stalled at each section, with a header summary "X readers · Y finished · Z in progress"). The structural advantage Scrivener cannot match: section-precise retention only works when authoring structure = reader structure.

## Skip permanently

- #9 Custom scene icons (color labels suffice).
- Compile dialog (publish replaces it).
- Section types / section layouts UI (irrelevant when output structure = input structure).

---

## Invariant

Whatever the writer does in the binder — nesting, labels, keywords, synopses, notes, snapshots — the published artifact is exactly what we ship today: a `WritingModel` with a list of `SectionModel.content` Quill Deltas. The binder is authoring scaffolding; the Quill Delta is the product. ✅ Verified end-to-end.
