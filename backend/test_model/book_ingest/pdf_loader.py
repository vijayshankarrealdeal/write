"""Phase 0 — load a PDF into Page objects. No LLM calls.

PyMuPDF (`fitz`) is fast and gives us blocks + the embedded TOC if the
publisher included one. Falls back gracefully when the TOC is missing.
"""

from __future__ import annotations

from typing import NamedTuple

import fitz  # PyMuPDF

from .boilerplate import strip_running_headers
from .schemas import Page


class TocEntry(NamedTuple):
    level: int
    title: str
    page: int  # 1-indexed


class LoadedPdf(NamedTuple):
    pages: list[Page]
    toc: list[TocEntry]


def load_pdf(path: str) -> LoadedPdf:
    doc = fitz.open(path)
    raw_texts: list[str] = []
    for page in doc:
        t = page.get_text("text") or ""
        raw_texts.append(t.strip())

    # Strip running headers/footers (book title repeated atop every page,
    # page numbers at the bottom). Done at the page level so the chunker
    # sees clean text and doesn't carry duplicated headers across joined
    # pages.
    cleaned = strip_running_headers(raw_texts)

    pages: list[Page] = [
        Page(no=i + 1, text=text, char_count=len(text))
        for i, text in enumerate(cleaned)
    ]

    toc_raw = doc.get_toc(simple=True) or []
    toc = [TocEntry(level=lvl, title=title.strip(), page=pg) for lvl, title, pg in toc_raw]
    doc.close()
    return LoadedPdf(pages=pages, toc=toc)
