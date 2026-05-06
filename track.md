# Writing Section Roadmap — Track

Status legend: ✅ done · 🟡 in progress · ⬜ pending

## P0 — Critical / quick wins
- ✅ #1 Smart quotes / dashes / ellipsis — commit 31b0f79
- ✅ #2 Persistent session goal + streak chip — commit 1e107e6
- ✅ #3 Section word-count + read-time in status bar — already shipped pre-roadmap
- ✅ Bug: writing_id UUID 422 — commit c8ccd7d (resolved)

## P1 — Major features
- 🟡 #4 Scrivenings — read-only v1 shipped (commit 066f416). Live multi-section editing PENDING — being implemented on branch `feat/scrivenings-live`.
- ⬜ #5 Footnotes (inline + inspector panel) — branch `feat/footnotes`
- ⬜ #6 Author bookmarks (in-document) — branch `feat/author-bookmarks`

## P2 — Polish / power features
- ⬜ #7 Linguistic Focus (POS-class highlighter w/ spaCy backend) — branch `feat/linguistic-focus`
- ⬜ #8 Page view / paginated layout — branch `feat/page-view`

## How this file is updated
Each feature branch updates this file in its final commit before merging to main, flipping its row from ⬜/🟡 to ✅ with the merge commit hash. Bugs discovered during work get appended at the bottom of their priority section.
