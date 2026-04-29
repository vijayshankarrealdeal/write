"""Phase 1 — group pages into Chunks. No LLM calls.

Strategy:
  1. If the PDF has a usable TOC, one chunk per top-level entry.
  2. Else, scan for heading lines (CHAPTER / BOOK / PART / Roman numerals).
  3. Else, sliding window of N pages.

The chunk is the unit of LLM work — too small wastes per-call overhead,
too large wastes tokens on low-importance chapters. Aim for ~3–10 pages.
"""

from __future__ import annotations

import hashlib
import re

from .boilerplate import clean_chunk_text, looks_like_front_matter
from .pdf_loader import LoadedPdf, TocEntry
from .schemas import Chunk, Page

_HEADING_RE = re.compile(
    r"^(?:CHAPTER|BOOK|PART|SECTION)\s+[IVXLC\d]+\b.*$",
    re.IGNORECASE | re.MULTILINE,
)
_FALLBACK_WINDOW = 5  # pages per chunk if no structure found


def chunk_pdf(loaded: LoadedPdf) -> list[Chunk]:
    """Strategy precedence: TOC > headings > sliding window. Each strategy
    feeds a tag into the chunk-id hash so switching strategies (because
    the chunker logic improved) invalidates old briefs cleanly.

    After chunking we clean each chunk's text (drop scanner / preface /
    Project Gutenberg boilerplate lines) and drop chunks that look like
    pure front-matter — readers don't want SECTION 1 to be a translator's
    methodology essay.
    """
    if _toc_is_usable(loaded.toc, total_pages=len(loaded.pages)):
        chunks = _chunk_by_toc(loaded.pages, loaded.toc)
    else:
        chunks = _chunk_by_headings(loaded.pages) or _chunk_by_window(
            loaded.pages, _FALLBACK_WINDOW
        )
    return _filter_and_clean(chunks)


_MIN_CHUNK_CHARS = 200  # below this, almost certainly a divider page


def _filter_and_clean(chunks: list[Chunk]) -> list[Chunk]:
    out: list[Chunk] = []
    for c in chunks:
        cleaned = clean_chunk_text(c.text)
        if not cleaned:
            continue
        # Tiny chunks are almost always section dividers ("Volume 2 - …"
        # spanning one page, "Book 3 - Aranya Kanda" with no body, an
        # OCR-garbled title page). Drop them so readers don't open the
        # book to a 60-char placeholder.
        if len(cleaned) < _MIN_CHUNK_CHARS:
            continue
        if looks_like_front_matter(cleaned):
            # Drop entirely — don't burn map/reduce tokens summarising it.
            continue
        if cleaned == c.text:
            out.append(c)
        else:
            # Recompute the deterministic id since the text changed.
            out.append(
                Chunk(
                    id=_chunk_id(_strategy_from_id(c.id), cleaned, c.page_start, c.page_end),
                    chapter_title=c.chapter_title,
                    page_start=c.page_start,
                    page_end=c.page_end,
                    text=cleaned,
                )
            )
    return out


def _strategy_from_id(_id: str) -> str:
    """We don't carry the strategy tag back from the id (it's hashed in).
    Use a single 'cleaned' tag so the new id is stable across re-runs of
    the cleanup step. This is just for cache-key uniqueness — the actual
    text + page range still discriminate correctly."""
    return "cleaned"


_TOC_PREFERRED_PAGES_PER_CHUNK = (2, 30)  # min, max — sweet spot for map-pass


def _toc_is_usable(toc: list[TocEntry], *, total_pages: int) -> bool:
    """A TOC is usable when *some* depth produces chunks of reasonable
    size (2–30 pages on average). For a 1700-page Ramayana with 8 L1
    entries the average is 200+ pages/chunk → unusable at L1 but
    excellent at L2 (~2.6 pages/chunk)."""
    if not toc:
        return False
    return _pick_toc_depth(toc, total_pages=total_pages) is not None


def _pick_toc_depth(toc: list[TocEntry], *, total_pages: int) -> int | None:
    """Return the deepest TOC level that yields chunks averaging
    `_TOC_PREFERRED_PAGES_PER_CHUNK` pages, or None if no level fits.

    Depth is chosen by walking from depth=1 upward and picking the
    deepest level with at least 3 entries and an average page span
    inside the preferred window. We prefer deeper because shallow TOCs
    (Books / Volumes) hide the actual chapters."""
    lo, hi = _TOC_PREFERRED_PAGES_PER_CHUNK
    levels = sorted({e.level for e in toc})
    best_depth: int | None = None
    for depth in levels:
        entries = [e for e in toc if e.level <= depth]
        if len(entries) < 3:
            continue
        avg = total_pages / len(entries)
        if lo <= avg <= hi:
            best_depth = depth        # deeper is better, keep updating
        elif avg < lo and best_depth is not None:
            # Going too granular now; stop at the previously best depth.
            break
    if best_depth is not None:
        return best_depth
    # Fallback: even if no depth lands inside the preferred window, take
    # the deepest level with at least 3 entries — better than the broken
    # all-in-one-chunk outcome of the old behaviour.
    for depth in reversed(levels):
        if sum(1 for e in toc if e.level <= depth) >= 3:
            return depth
    return None


def _chunk_by_toc(pages: list[Page], toc: list[TocEntry]) -> list[Chunk]:
    depth = _pick_toc_depth(toc, total_pages=len(pages)) or 1
    entries = [e for e in toc if e.level <= depth]
    # Sort by page so we can take consecutive boundaries.
    entries.sort(key=lambda e: e.page)
    chunks: list[Chunk] = []
    for i, entry in enumerate(entries):
        start = max(1, entry.page)
        end = (entries[i + 1].page - 1) if i + 1 < len(entries) else len(pages)
        if end < start:
            end = start
        text = _join_pages(pages, start, end)
        if not text:
            continue
        chunks.append(
            Chunk(
                id=_chunk_id("toc", text, start, end),
                chapter_title=entry.title,
                page_start=start,
                page_end=end,
                text=text,
            )
        )
    return chunks


def _chunk_by_headings(pages: list[Page]) -> list[Chunk]:
    boundaries: list[tuple[int, str]] = []
    for p in pages:
        m = _HEADING_RE.search(p.text)
        if m:
            boundaries.append((p.no, m.group(0).strip()))

    if len(boundaries) < 3:
        return []

    chunks: list[Chunk] = []
    for i, (page_no, title) in enumerate(boundaries):
        end = (boundaries[i + 1][0] - 1) if i + 1 < len(boundaries) else len(pages)
        text = _join_pages(pages, page_no, end)
        if not text:
            continue
        chunks.append(
            Chunk(
                id=_chunk_id("heading", text, page_no, end),
                chapter_title=title,
                page_start=page_no,
                page_end=end,
                text=text,
            )
        )
    return chunks


def _chunk_by_window(pages: list[Page], window: int) -> list[Chunk]:
    chunks: list[Chunk] = []
    for start in range(1, len(pages) + 1, window):
        end = min(start + window - 1, len(pages))
        text = _join_pages(pages, start, end)
        if not text:
            continue
        chunks.append(
            Chunk(
                id=_chunk_id("window", text, start, end),
                chapter_title=None,
                page_start=start,
                page_end=end,
                text=text,
            )
        )
    return chunks


def _join_pages(pages: list[Page], start: int, end: int) -> str:
    return "\n\n".join(p.text for p in pages if start <= p.no <= end and p.text)


def _chunk_id(strategy: str, text: str, page_start: int, page_end: int) -> str:
    """Deterministic chunk id — same input PDF + same chunker logic
    produces the same id, so resumes match cached briefs/deeps cleanly.
    The strategy tag is part of the hash so a future chunker change
    invalidates the cache instead of silently mixing data."""
    payload = f"{strategy}|{page_start}|{page_end}|{text}".encode("utf-8")
    return hashlib.sha1(payload).hexdigest()[:12]
