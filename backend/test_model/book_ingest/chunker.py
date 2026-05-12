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

# Chapter-heading detection for PDFs that have no usable TOC. Broad
# enough to catch the shapes we see across the test corpus:
#   "CHAPTER I.", "Chapter 12: The Hunt", "Chapter the First"
#   "BOOK II", "Part III — The Return", "Section 4"
#   "Letter 1", "CANTO V", "Prologue", "Epilogue"
#   "Act II", "Scene 3"
# We keep this line-anchored (^) so a mid-paragraph mention of the word
# "chapter" doesn't accidentally split the book.
_HEADING_RE = re.compile(
    r"^\s*(?:CHAPTER|BOOK|PART|SECTION|LETTER|CANTO|ACT|SCENE)"
    r"\s+(?:[IVXLCDM]+|\d+|the\s+(?:first|second|third|fourth|fifth|sixth|"
    r"seventh|eighth|ninth|tenth|eleventh|twelfth)|one|two|three|four|"
    r"five|six|seven|eight|nine|ten|eleven|twelve)\b.*$"
    r"|^\s*(?:PROLOGUE|EPILOGUE|FOREWORD|AFTERWORD)\b.*$",
    re.IGNORECASE | re.MULTILINE,
)
_FALLBACK_WINDOW = 5  # pages per chunk if no structure found

# Single-chapter safety net (see `_split_oversized_chunks`). Triggered
# when a "chapter" is way too long to be one — typical chapters in the
# existing books sit between 10K-20K chars; anything over this is
# almost certainly an unbroken wall of text the structure detection
# missed.
_OVERSIZED_CHUNK_CHARS = 30_000
# Target piece size when we synthesise chapters from a single blob.
# ~2,500 words / ~12-15 min reading per chapter.
_TARGET_PIECE_CHARS = 14_000
# Min piece size — anything shorter is a near-empty fragment we
# shouldn't bother promoting to its own chapter.
_MIN_PIECE_CHARS = 1_200


def chunk_pdf(loaded: LoadedPdf) -> list[Chunk]:
    """Strategy precedence: TOC > headings > sliding window. Each strategy
    feeds a tag into the chunk-id hash so switching strategies (because
    the chunker logic improved) invalidates old briefs cleanly.

    After chunking we clean each chunk's text (drop scanner / preface /
    Project Gutenberg boilerplate lines) and drop chunks that look like
    pure front-matter — readers don't want SECTION 1 to be a translator's
    methodology essay.

    Final safety net: if the result is one giant chunk (or two with one
    giant chunk), the book never got chunked at all — its TOC was empty,
    no recognised chapter-heading regex matched, and the sliding-window
    fallback gave a single window because the loader emitted only one
    page. We then synthesise chapters by length so readers don't open
    the book to a 30-minute wall of text. See `_split_oversized_chunks`.
    """
    if _toc_is_usable(loaded.toc, total_pages=len(loaded.pages)):
        chunks = _chunk_by_toc(loaded.pages, loaded.toc)
    else:
        chunks = _chunk_by_headings(loaded.pages) or _chunk_by_window(
            loaded.pages, _FALLBACK_WINDOW
        )
    chunks = _filter_and_clean(chunks)
    return _split_oversized_chunks(chunks)


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


# Upper bound for "this TOC level is the chapter level" — a typical novel
# chapter sits between 5 and 50 pages; multi-volume works (Ramayana,
# Mahābhārata) put Books at level 1 with 200+ pages each, which is why we
# drop a level when level 1 is too coarse. 60 leaves headroom for long
# chapters (Moby Dick, Les Misérables) without flipping into sub-section
# territory.
_TOC_CHAPTER_PAGES_MAX = 60
_TOC_MIN_ENTRIES = 3


def _toc_is_usable(toc: list[TocEntry], *, total_pages: int) -> bool:
    """A TOC is usable when *some* depth has at least three entries.
    Depth selection itself is owned by `_pick_toc_depth`."""
    if not toc:
        return False
    return _pick_toc_depth(toc, total_pages=total_pages) is not None


def _pick_toc_depth(toc: list[TocEntry], *, total_pages: int) -> int | None:
    """Return the *shallowest* TOC level whose average pages-per-entry
    is small enough to be a real chapter (≤ `_TOC_CHAPTER_PAGES_MAX`).

    Rationale — the user-facing chapter list should be the book's
    chapter list. For a 400-page, 12-chapter novel we want 12 sections
    (level 1 → avg 33 pp/chunk), not 60+ sections from level 2 of a
    sub-divided TOC. For a 1700-page Ramayana with level 1 = 8 Books
    (avg 212 pp), level 1 is too coarse — we drop to level 2 where the
    644 sargas average 2.6 pp.

    The old heuristic preferred the *deepest* level that fit a narrow
    2–30 page band, which broke chapter-grain selection for moderately
    long novels whose chapters span 30–60 pages.
    """
    levels = sorted({e.level for e in toc})
    for depth in levels:
        entries = [e for e in toc if e.level <= depth]
        if len(entries) < _TOC_MIN_ENTRIES:
            continue
        avg = total_pages / len(entries)
        if avg <= _TOC_CHAPTER_PAGES_MAX:
            return depth
    # Last resort: deepest level with enough entries — only fires when
    # every level has fewer than three entries OR every level averages
    # more than the chapter ceiling (rare, e.g. a 5-entry TOC for a
    # 1000-page book). Better than emitting one mega-chunk per book.
    for depth in reversed(levels):
        if sum(1 for e in toc if e.level <= depth) >= _TOC_MIN_ENTRIES:
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


# -----------------------------------------------------------------------
# Single-chapter safety net
# -----------------------------------------------------------------------

# Detect markdown headings like `## STORY OF THE DOOR` or `### Letter 4`
# that survived inside a chunk because the upstream loader's chapter
# regex was too narrow (e.g. Jekyll & Hyde uses uppercase title headings
# that don't start with the word "CHAPTER").
_MD_HEADING_RE = re.compile(r"^(#{1,3})\s+(.+?)\s*$", re.MULTILINE)
# 3+ asterisks on a line — common scene-break / chapter-break marker
# in older texts ("    *    *    *    ").
_ASTER_DIVIDER_RE = re.compile(r"\n[ \t]*(?:\*[ \t]*){3,}\n")


def _split_oversized_chunks(chunks: list[Chunk]) -> list[Chunk]:
    """Break a single-chunk-style book into chapter-sized pieces.

    Conservative trigger — fires only when the book genuinely has no
    chunking structure to speak of:
      • 1 or 2 chunks total, AND
      • at least one of them is longer than `_OVERSIZED_CHUNK_CHARS`.

    Multi-chunk books with one anomalous long chapter (e.g. Frederick
    Douglass: 12 chunks, one of 68K chars) are left alone — that's an
    authorial choice, not a chunker miss.

    Split-point precedence:
      1. Markdown `## Heading` lines inside the chunk — these are the
         real chapter titles the loader missed. Promotes them to
         actual chapter_titles.
      2. Asterisk dividers (`* * *`) — common scene/chapter breaks.
      3. Paragraph rolling — accumulate paragraphs until the target
         size, break at the next blank line. Synthetic "Chapter N"
         titles.
    """
    if not chunks:
        return chunks
    if len(chunks) > 2:
        return chunks
    if not any(len(c.text) > _OVERSIZED_CHUNK_CHARS for c in chunks):
        return chunks

    out: list[Chunk] = []
    chapter_counter = 1
    for c in chunks:
        if len(c.text) <= _OVERSIZED_CHUNK_CHARS:
            out.append(c)
            chapter_counter += 1
            continue

        pieces = _break_oversized_text(c.text)
        if len(pieces) < 2:
            out.append(c)
            chapter_counter += 1
            continue

        print(
            f"[chunker] single-chapter book ({len(c.text):,} chars) — "
            f"split into {len(pieces)} chapters"
        )
        for title, body in pieces:
            new_title = title or (
                f"{c.chapter_title} — Part {chapter_counter}"
                if c.chapter_title
                else f"Chapter {chapter_counter}"
            )
            out.append(
                Chunk(
                    id=_chunk_id("split", body, c.page_start, c.page_end),
                    chapter_title=new_title,
                    page_start=c.page_start,
                    page_end=c.page_end,
                    text=body,
                )
            )
            chapter_counter += 1
    return out


def _break_oversized_text(text: str) -> list[tuple[str | None, str]]:
    """Return [(title_or_none, body), ...] for `text`.

    Title is filled when the split point was a markdown heading.
    Falls back to (None, body) for asterisk and paragraph splits —
    `_split_oversized_chunks` synthesises Chapter N titles in that case.
    """
    md_pieces = _split_at_md_headings(text)
    if md_pieces is not None:
        return md_pieces

    aster_pieces = _split_at_asterisks(text)
    if aster_pieces is not None:
        return [(None, body) for body in aster_pieces]

    return [(None, body) for body in _split_at_paragraphs(text, _TARGET_PIECE_CHARS)]


def _split_at_md_headings(text: str) -> list[tuple[str | None, str]] | None:
    """Split on `^##+ heading` lines. Returns None when there aren't
    enough headings (<3) or when the headings cluster too unevenly
    (e.g. one giant section followed by 8 micro-sections — likely
    the headings aren't real chapter breaks)."""
    headings: list[tuple[int, int, str]] = []  # (line_start, body_start, title)
    for m in _MD_HEADING_RE.finditer(text):
        title = m.group(2).strip()
        if not title:
            continue
        line_start = m.start()
        body_start = m.end()
        headings.append((line_start, body_start, title))
    if len(headings) < 3:
        return None

    pieces: list[tuple[str | None, str]] = []
    for i, (_, body_start, title) in enumerate(headings):
        end = headings[i + 1][0] if i + 1 < len(headings) else len(text)
        body = text[body_start:end].strip()
        if len(body) < _MIN_PIECE_CHARS:
            # Skip tiny leading-title-page slivers (e.g. Jekyll's "## by
            # Robert Louis Stevenson" right under the title).
            continue
        pieces.append((title, body))
    if len(pieces) < 3:
        return None
    return pieces


def _split_at_asterisks(text: str) -> list[str] | None:
    parts = [p.strip() for p in _ASTER_DIVIDER_RE.split(text)]
    parts = [p for p in parts if len(p) >= _MIN_PIECE_CHARS]
    if len(parts) < 3:
        return None
    return parts


def _split_at_paragraphs(text: str, target_chars: int) -> list[str]:
    """Greedy paragraph accumulation. Breaks at the first blank line
    after we've gathered at least `target_chars // 2` characters,
    aiming to land near `target_chars` per piece without slicing
    mid-paragraph.

    A single paragraph that's longer than the target is kept whole
    rather than mid-sentence chopped — better one long chapter than
    mangled prose.
    """
    paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]
    if not paragraphs:
        return []
    pieces: list[str] = []
    current: list[str] = []
    current_len = 0
    soft_floor = target_chars // 2
    for para in paragraphs:
        addition = len(para) + (2 if current else 0)
        if current and current_len >= soft_floor and current_len + addition > target_chars:
            pieces.append("\n\n".join(current))
            current = [para]
            current_len = len(para)
        else:
            current.append(para)
            current_len += addition
    if current:
        pieces.append("\n\n".join(current))
    return pieces
