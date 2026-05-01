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

- [x] Version history: `SectionVersion` model — full Quill Delta JSON snapshot + word count + manual flag + label
- [x] Version history: Hive-backed per-section storage in `StorageService`
- [x] Version history: `VersionHistoryProvider` with idle (30s) auto-snapshot, manual capture, retention prune (50 recent autos + 1/day for 30 days; manuals never expire)
- [x] Version history: non-destructive `restore` — captures current state as a labeled "before-restore" snapshot before swapping
- [x] Version history: provider registered in `main.dart`
- [x] Version history: doc-change listener attached on section load triggers `scheduleSnapshot`; detached on dispose / section switch
- [x] Version history: `flush` on app pause / inactive / detached so suspends don't lose the last snapshot
- [x] Version history: settings sheet gains "Version history" + "Save current as named version" entries
- [x] Version history: bottom-sheet `_VersionHistorySheet` lists snapshots, distinguishes manual vs auto, restore + delete + save-current

- [x] Spell-check: dictionary moved to backend (`backend/app/data/en_us.txt`, ~210k words). FastAPI `/api/spellcheck/check` + `/api/spellcheck/suggest` (auth-required, dictionary loaded once, DL suggestions in a thread executor)
- [x] Spell-check: frontend `SpellCheckService` is now a thin HTTP client; ignored words are sent server-side so future dict swaps need no app build
- [x] Spell-check: `SpellCheckProvider` debounces scan (~800ms — slightly longer to absorb network latency), persists enable + personal "ignore" list per user, exposes async `suggest()` for the sheet
- [x] Spell-check: provider wired in `main.dart` with an `ApiClient`-backed service
- [x] Spell-check: status-bar chip shows issue count, click → `_SpellCheckSheet`. Suggestion chips load lazily on row expand with a small spinner
- [x] Spell-check: Writer Settings → "Editing assist" → spell check toggle (defaults on)
- [x] Spell-check: section change reattaches the provider to the active QuillController

## What's in progress

(none — spell-check inline squiggle painting is parked as a follow-up; see Open questions.)

## What's left

(See in-progress — none not yet started beyond what's listed.)

## Open questions to revisit

- Annotation panel placement — right floating pill is currently duplicate of left rail; consider folding annotations into one of them.
- Where does the version-history entry point live? Settings sheet, or a dedicated icon in the top bar? (Currently in settings.)
- **Inline spell-check squigglies** — v1 ships with a status-bar chip + sheet (jump + replace), no in-document underlines. Painting requires either a custom Quill embed/attribute pass or a CustomPainter overlay tied to QuillEditor's text layout. Shippable as a follow-up; defer until perf on a 10k-word section is measured.
- **Dictionary size** — now backend-resident, so client download is unaffected. Server still loads ~2MB into memory on first call; could move to Redis/SQLite if a second worker is added.
- **Offline behavior** — checks now require network. Provider returns empty issues on API failure so the editor stays usable; consider a cached "last known issues" mode if users complain.
- Spell-check has no grammar layer — that's the future server-side LanguageTool integration.
