# Editor UI build tracker

Working list for: comments/annotations, version history, offline spell-check.

## Decisions (assumed in auto mode)

- **Annotations**: single-user margin notes for v1, but model carries `authorId` so it can extend to multi-user later. Local-first via Hive (mirrors how books are stored). Backend sync stubbed for now.
- **Anchor strategy**: store `(start, length, anchoredText)`. On load, if text at offset doesn't match, fuzzy-reanchor by searching for `anchoredText` in the document. Mark as "orphaned" if not found.
- **Version history**: snapshot on idle (~30s after last edit) plus session-close. Cap: last 50 + one daily for 30 days. Local-first.
- **Spell-check**: bundle a small SymSpell-style dictionary (~50k common English words) for offline coverage on every platform. Damerau-Levenshtein lookup in an isolate. Right-click / long-press → suggestions. Server-side LanguageTool layer is future work.

## What's done

- [x] px.md tracker created
- [x] Annotations: `EditorAnnotation` + `EditorAnnotationReply` model with anchor metadata, JSON encode/decode
- [x] Annotations: Hive-backed per-section storage in `StorageService` (per-user-scoped keys)
- [x] Annotations: `AnnotationProvider` with load/add/update/resolve/remove + `shiftAnchors` reflow + fuzzy reanchor on load
- [x] Annotations: provider registered in `main.dart`
- [x] Annotations: "Comment" action added to floating selection toolbar
- [x] Annotations: 5th button on floating side pill toggles the panel; unread badge from provider
- [x] Annotations: comment compose dialog (anchored snippet preview + body)
- [x] Annotations: right-side `_AnnotationsPanel` lists all comments, jump-to-anchor, resolve/reopen, delete
- [x] Annotations: Quill `BackgroundAttribute` paints a yellow tint on the anchored range — the marker auto-tracks edits via Quill's delta
- [x] Annotations: section change detection via `context.select` reloads provider on switch

## What's in progress

- [ ] Version history: snapshot model + storage + scheduler
- [ ] Version history: editor sheet (list, preview, restore)
- [ ] Spell-check: dictionary + suggestion engine in isolate
- [ ] Spell-check: overlay underlines + suggestion menu in Quill

## What's left

(See in-progress — none not yet started beyond what's listed.)

## Open questions to revisit

- Annotation panel placement — right floating pill is currently duplicate of left rail; consider folding annotations into one of them.
- Where does the version-history entry point live? Settings sheet, or a dedicated icon in the top bar?
- Spell-check on Quill needs a custom paint pass — confirm performance on long sections (>10k words) before shipping.
