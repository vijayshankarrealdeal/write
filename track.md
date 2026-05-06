# Writing Section Roadmap — Track

Status legend: ✅ merged to main · 🟢 implementation complete, PR open · 🟡 in progress · ⬜ pending

## P0 — Critical / quick wins
- ✅ #1 Smart quotes / dashes / ellipsis — commit 31b0f79
- ✅ #2 Persistent session goal + streak chip — commit 1e107e6
- ✅ #3 Section word-count + read-time in status bar — already shipped pre-roadmap
- ✅ Bug: writing_id UUID 422 — commit c8ccd7d (resolved)

## P1 — Major features
- ✅ #4 Scrivenings — read-only v1 merged (commit 066f416); live multi-section editing merged via PR [#9](https://github.com/vijayshankarrealdeal/write/pull/9) (branch commit 02274c3, merge commit 78f85ff).
- ✅ #5 Footnotes (inline + inspector panel + endnote publish) — merged via PR [#10](https://github.com/vijayshankarrealdeal/write/pull/10) (branch commit 8e2c540, merge commit e339e65).
- ✅ #6 Author bookmarks (in-document) — merged via PR [#12](https://github.com/vijayshankarrealdeal/write/pull/12) (branch commit d4d9652 after rebase, merge commit 363cb2b).

## P2 — Polish / power features
- ✅ #7 Linguistic Focus (POS-class highlighter w/ spaCy backend) — merged via PR [#13](https://github.com/vijayshankarrealdeal/write/pull/13) (branch commit 924434e, merge commit a01f948).
- ✅ #8 Page view / paginated layout — merged via PR [#11](https://github.com/vijayshankarrealdeal/write/pull/11) (branch commit 1ac187c, merge commit 8dd7be9). Live in-page editing followed in PR [#14](https://github.com/vijayshankarrealdeal/write/pull/14) (branch commit 6d742ec, merge commit b440df4) — the read-only scope-cut from v1 is now closed. The two multi-section live editors (Scrivenings + Page view) share a common `MultiSectionEditingSession` extracted in #14, so future edit-routing changes land in one place.

## How this file is updated
Each feature branch updates this file in its final commit before merging to main, flipping its row through ⬜ → 🟡 → 🟢 (when the PR opens) → ✅ (when it merges, with the merge commit hash). Bugs discovered during work get appended at the bottom of their priority section.
