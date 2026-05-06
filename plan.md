# InkSpaceX Writing Experience — Plan

Goal: close the remaining gap to Scrivener for the **drafting / editor experience** (not project management or compile/export). Source of truth for the bigger structural work is [Scrivener.md](Scrivener.md); this file is a focused engineering punch list.

> **Scope correction since the original comparison.** Two items I previously listed as missing are already shipped and need no work:
> - **Typewriter scrolling** — implemented in [editor_page_entry.dart:1057-1100](lib/ui/pages/editor_page_entry/editor_page_entry.dart) (`_attachTypewriterListenerIfNeeded`, `_scheduleTypewriterRecenter`); user-toggle at line 2117.
> - **Daily goal + streak** — `DailyGoalService` is wired through the editor at [editor_page_entry.dart:135-295](lib/ui/pages/editor_page_entry/editor_page_entry.dart) and surfaced in the side panel (`$_streak-day streak`, line 2442) and focus mode footer (line 4482).
>
> P0 below is reshaped accordingly.

---

## P0 — Critical / quick wins

### 1. Smart quotes, dashes, and ellipsis ✅
**Done in commit `31b0f79`** — `SmartSubstitutions.compute` is a pure transformer in [smart_substitutions.dart](lib/services/smart_substitutions.dart); `_maybeSmartSubstitute` wires it into the editor's doc-changes listener; toggle lives next to Typing Haptics in the editor settings sheet; preference persists via `SharedPreferences` (default on); 14 unit tests cover the rules. Per-project (vs per-app) toggle deferred — would have required a backend schema change disproportionate to a P0 quick win.

**What.** Replace `"` with `“ ”`, `'` with `‘ ’`, `--` with `—`, `...` with `…` as the user types. Per-project toggle in settings.
**Where.**
- New `lib/services/smart_substitutions.dart` — pure transformer over a Quill Delta diff.
- Hook in [editor_page_entry.dart](lib/ui/pages/editor_page_entry/editor_page_entry.dart) where the QuillController document listener fires (search for `_docSubscription` setup near line 1038).
- Setting toggle in [project_settings_dialog.dart](lib/ui/pages/editor_page_entry/writing_page/project_settings_dialog.dart) and persistence on `WritingModel`.
**Effort.** 0.5–1 day.
**Acceptance.** Type `"hello"` → renders `“hello”`. Type `--` → `—`. Type `...` → `…`. Backspace once after substitution restores the original keystroke (so users can opt out per-instance). Toggle off disables all four.

### 2. Session target footer chip in the editor chrome
**What.** Daily goal/streak exist but live in side panels and focus-mode only. Add a persistent low-key chip in the main editor footer/toolbar showing `<wordsToday> / <goal> · 🔥<streak>` so it's visible during normal drafting, not just in focus.
**Where.**
- [editor_page_entry.dart](lib/ui/pages/editor_page_entry/editor_page_entry.dart) — render in the bottom toolbar row alongside save status. Reuses existing `_dailyWordsToday`, `_dailyGoal`, `_streak` state (no new service).
**Effort.** 2–3 hours.
**Acceptance.** Chip visible in non-focus editor on web + mobile. Tapping opens the existing goal-edit dialog. Counter updates live as the user types.

### 3. Section-scoped word count + read-time estimate
**What.** Today the focus-mode counter is total. Add a small chip in the section toolbar: `<sectionWords> words · <minutes> min read`. Cheap, high signal.
**Where.**
- [editor_constants.dart](lib/ui/pages/editor_page_entry/writing_page/editor_constants.dart) for the words-per-minute constant (use 250).
- New widget alongside [focus_widgets.dart](lib/ui/pages/editor_page_entry/writing_page/focus_widgets.dart) — `SectionMetricsChip`.
- Wire from the Quill plain-text length the autosave path already computes ([editor_provider.dart `dumpData`](lib/provider/editor_provider.dart)).
**Effort.** 2 hours.
**Acceptance.** Counter updates within 1s of stopping typing; matches manual count to ±1 word; shows `<1 min` floor.

---

## P1 — Major features

### 4. Scrivenings mode (continuous scroll across selected sections)
**What.** When the user multi-selects sections in the binder (or selects Manuscript root), render their Quill deltas concatenated into one editor with subtle separators between scenes. Editing a region writes back to the originating section.
**Where.**
- New `lib/ui/pages/editor_page_entry/writing_page/scrivenings_view.dart`.
- Add a fourth view to [view_switcher.dart](lib/ui/pages/editor_page_entry/writing_page/views/view_switcher.dart) (alongside cards / outline / single).
- Mapping logic: maintain `List<({String sectionId, int startOffset, int endOffset})>` so a controller change can be routed to the right section's autosave. Pattern can borrow from [publish_page.dart](lib/ui/pages/publish_page.dart) which already concatenates deltas for output.
- Outbox: each section is still its own `upsertSection` op; only the active region's section gets a queue entry.
**Effort.** 4–6 days. The offset bookkeeping is the hard part.
**Acceptance.** Selecting 3 chapters renders all three in one scroll with section dividers. Edit in chapter 2 → only chapter 2's `updatedAt` changes. Splitting a chapter (Enter at a divider creates a new scene? — defer) is **not** required for v1.

### 5. Footnotes (inline + inspector)
**What.** Inline marker `¹` in the prose; full footnote text edited in a dedicated bottom panel. Persisted as a Quill custom embed with a stable id; rendered both in the editor and in published output.
**Where.**
- Custom Quill embed: new `lib/ui/editor/footnote_embed.dart` (model + builder).
- Storage: extend [section_model.dart](lib/models/section_model.dart) with `Map<String, String> footnotes` keyed by embed id.
- New panel beside [annotations_panel.dart](lib/ui/pages/editor_page_entry/writing_page/annotations_panel.dart) — `footnotes_panel.dart` listing all footnotes for the active section, click-to-jump.
- Publish path: extend [publish_page.dart](lib/ui/pages/publish_page.dart) to render footnotes as endnotes (or per-page in the future).
- Backend: footnotes ride inside the existing `content` JSON, so no schema change.
**Effort.** 4–5 days.
**Acceptance.** Insert footnote via toolbar → marker appears, panel focuses the new entry. Reload reproduces footnotes in order. Publish view shows them as endnotes at the chapter end.

### 6. Author bookmarks (in-document)
**What.** Author-side flag-this-spot markers (distinct from the existing reader-side [BookmarkModel](lib/models/bookmark_model.dart) which anchors reader bookmarks). A small flag icon in the gutter, listed in the Inspector; click to jump.
**Where.**
- New `lib/models/author_bookmark.dart` (id, sectionId, offset, label, createdAt).
- Add to [section_inspector.dart](lib/ui/pages/editor_page_entry/writing_page/section_inspector.dart) as a third tab next to Synopsis and Notes.
- Storage piggybacks on `SectionModel` (avoid a new outbox op kind for v1).
**Effort.** 2 days.
**Acceptance.** Cmd-D / long-press in the editor adds a bookmark at the cursor with an optional label. The Inspector lists them. Click jumps the editor to the offset.

---

## P2 — Polish / power features

### 7. Linguistic Focus (highlight by part-of-speech)
**What.** Toggleable overlay that fades all text except dialogue / adverbs / adjectives / nouns / verbs. Useful for self-editing.
**Where.**
- New `lib/services/linguistic_focus.dart` — POS tagger. Options: ship with a small JS-port library, or call a backend `/api/linguistic/tag` endpoint that uses spaCy. **Backend-first** is the right call here per project preference.
- New backend route `backend/app/routers/linguistic.py` returning span offsets for each requested class.
- Editor overlay: extend the Quill paint pipeline (or use a custom `EditorBuilder` wrap) to dim non-matching spans. Pattern can borrow from [spell_check_decoration.dart](lib/services/spell_check_decoration.dart) which already does span-based decoration.
**Effort.** 1–1.5 weeks (backend + client + 5 categories).
**Acceptance.** Toggle "Dialogue" → only quoted strings stay full opacity. Toggle "Adverbs" → only `-ly` and tagged adverbs stay full opacity. Works on a 5k-word section without typing lag.

### 8. Page view / paginated layout
**What.** Optional page-shaped layout (8.5×11 / A4 with margins) so the writer sees approximate manuscript pages. Pure render mode; storage unchanged.
**Where.**
- New `lib/ui/pages/editor_page_entry/writing_page/page_view_layout.dart` — wraps the existing Quill editor in a paginated `CustomScrollView` with page-break markers.
- Toggle in [view_switcher.dart](lib/ui/pages/editor_page_entry/writing_page/views/view_switcher.dart).
- Page break heuristic: ~250 words per page (configurable).
**Effort.** 3–5 days. Performance is the risk — must not re-layout the whole document on each keystroke.
**Acceptance.** Toggling page view reflows current section into discrete pages without losing the cursor. Word count chip switches to `Page X of Y`. Disabling restores continuous scroll.

---

## Bugs / known issues

- **`writing_id` UUID 422 on section autosave** — *Resolved* in commit `c8ccd7d`. New books and sections now mint UUIDv4; legacy digit-only book ids are migrated on load with an `isNew=true` upsertWriting enqueued. See [editor_provider.dart `addNewBook` / `_migrateLegacyBookIds`](lib/provider/editor_provider.dart).
- **`addSection` still uses `DateTime.now().millisecondsSinceEpoch.toString()` for legacy callers** — Fixed in the same commit; verify no other section-creation paths slipped through (grep for `millisecondsSinceEpoch.toString()` in `lib/provider/`).
- **[editor_page_entry.dart](lib/ui/pages/editor_page_entry/editor_page_entry.dart) is 4,813 lines** — long-lived god widget. Not a functional bug, but it makes every P1 change above harder than it needs to be. Worth a structural extraction pass (toolbar, footer, listeners) before P1 lands. Out of scope for this plan; spin off as its own task.
- **[editor_provider.dart](lib/provider/editor_provider.dart) is 1,983 lines** — same shape problem. The legacy ghost-fix / folder-migration / outbox-rewrite paths are doing real work; a follow-up extraction into `lib/provider/editor/` modules would pay off.
- **No automatic snapshot before AI rewrite** — [Scrivener.md §2.10](Scrivener.md) flags this as a one-line add in the AI service hook ([ai_bottom_sheet.dart](lib/ui/pages/editor_page_entry/writing_page/ai_bottom_sheet.dart) / [grow_shrink_button.dart](lib/ui/pages/editor_page_entry/writing_page/grow_shrink_button.dart)). Currently the user can lose generated text on regret. Easy P0 candidate if prioritized — left out above only because the user's P0 list was specific.
- **Test infra: [test/widget_test.dart](test/widget_test.dart) `App initializes correctly` times out at 10 min** — `pumpAndSettle` over the full app never settles. Pre-existing; muddies CI signal. Worth a separate fix (replace with a narrow smoke test that pumps a single frame).

---

## Out of scope

- **Compile dialog / export configuration** — InkSpaceX wins by deletion here; publish remains "structure = output" per [Scrivener.md §2.11](Scrivener.md) and the existing [publish_page.dart](lib/ui/pages/publish_page.dart). Do not reintroduce.
- **Custom scene icons** — color labels already in `section_inspector` cover the same need.
- **Section types / section layouts UI** — irrelevant when output structure equals input structure.
- **Project-wide search across writings** — useful but is reader/library territory, not the drafting editor.
