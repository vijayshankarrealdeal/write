"""Phase 0 (HTML variant) — load a Project Gutenberg HTML file into Page
objects. No LLM calls.

Gutenberg HTML is semantic: chapters live inside `<section id="pg-header">`
… `<section id="pg-footer">` PG boilerplate, with a title page + TOC
between the front boilerplate and the first chapter heading.

Strategy:
  1. Drop the two `<section class="pg-boilerplate">` blocks (kills license).
  2. Read title / author / subjects from `<meta>` tags.
  3. Find the first `<h2>` whose text matches a chapter pattern
     (Chapter I, Letter 1, Book the First, etc.). Everything before it
     in the body is treated as front matter and dropped — this kills the
     title page, "by Author" line, Contents heading, the TOC list, and
     any repeated title — *without* touching real chapter "Letter N"
     headings inside epistolary novels (those are matched by the same
     regex as chapters, so they stay).
  4. Split the remaining body at every `<h2>` and emit one Page per
     chapter, with chapter title in the Page-level metadata via the
     synthetic `Page.no = chapter_index`.
  5. Convert each chapter's HTML to clean markdown (italics, bold,
     blockquote, scene-break hr preserved). No LLM cleanup needed.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable, NamedTuple

from bs4 import BeautifulSoup, Comment, NavigableString, Tag

# Pick the fastest available parser. `lxml` is fastest but is a C
# extension that requires the system libxml2; on a fresh dev box it
# isn't always installed. `html.parser` ships with the stdlib and
# handles Project Gutenberg HTML just fine — it's slower (a few
# hundred ms on a 5 MB file vs lxml's ~50 ms) but never missing.
try:
    import lxml  # noqa: F401
    _BS4_PARSER = "lxml"
except ImportError:
    _BS4_PARSER = "html.parser"

from .schemas import Page


# A heading is "a chapter" if its text starts with one of these words
# (case-insensitive), optionally followed by a numeral. Matches:
#   "Chapter 1", "CHAPTER I", "Chapter the First",
#   "Letter 1", "LETTER IV.",
#   "Book I", "Part Two", "Prologue", "Epilogue",
#   "Act I", "Scene II"
_CHAPTER_RE = re.compile(
    r"^\s*(chapter|letter|book|part|prologue|epilogue|act|scene|canto)\b",
    re.IGNORECASE,
)

# Pure roman / arabic numeral headings are also accepted as chapter
# starts (some 19th-century books use bare "I.", "II.", "III." headings).
_NUMERAL_RE = re.compile(r"^\s*[IVXLCDM]+\.?\s*$|^\s*\d+\.?\s*$", re.IGNORECASE)

# Numeral + delimiter + capitalised title: "I. A SCANDAL IN BOHEMIA",
# "1. THE BEGINNING", "II.—The Red-Headed League" — the canonical
# modern Project Gutenberg chapter-heading shape. Requires an uppercase
# letter after the delimiter so we don't match "1.99 dollars" inside
# stray body text accidentally classified as a heading.
_LEADING_NUMERAL_TITLE_RE = re.compile(
    r"^\s*(?:[IVXLCDM]+|\d{1,3})\s*[.\-—:)]\s*[A-Z]"
)

# Headings whose text matches one of these is *front matter* — we drop
# them and everything they contain. Order matters: we only apply this
# denylist to headings that appear *before* the first chapter heading,
# so a real chapter called "Introduction" inside the body is safe.
_FRONT_MATTER_HEADINGS = {
    "contents",
    "table of contents",
    "list of illustrations",
    "illustrations",
    "list of plates",
    "transcriber's note",
    "transcriber's notes",
}


# Fallback title→author lookup is owned by `known_authors.py` so the
# repair script can import it inside the production fastapi container
# without dragging bs4 along. Re-exported for backwards compat.
from .known_authors import lookup_known_author  # noqa: F401


class TocEntry(NamedTuple):
    level: int
    title: str
    page: int  # 1-indexed; matches the synthetic Page.no


@dataclass
class LoadedHtml:
    """Mirrors `pdf_loader.LoadedPdf` so the rest of the pipeline doesn't
    need to know which path produced it."""
    pages: list[Page]
    toc: list[TocEntry]
    title: str | None = None
    author: str | None = None
    subjects: list[str] | None = None


# -----------------------------------------------------------------------
# Public entrypoint
# -----------------------------------------------------------------------

def load_html(path: str) -> LoadedHtml:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
    soup = BeautifulSoup(raw, _BS4_PARSER)

    title, author, subjects = _read_metadata(soup)

    # Strip Gutenberg's wrapper boilerplate (header license, footer license).
    for sect in soup.select("section.pg-boilerplate"):
        sect.decompose()

    body = soup.body or soup

    # Strip non-content tags inside the body.
    for tag in body.find_all(["script", "style", "link", "meta", "noscript"]):
        tag.decompose()

    # Strip HTML comments — Gutenberg sprinkles `<!--end chapter-->`
    # between chapter divs which would otherwise render as literal text.
    for c in body.find_all(string=lambda s: isinstance(s, Comment)):
        c.extract()

    # Walk the body, find the first chapter-pattern heading. Everything
    # before it is front matter — drop it. This safely removes the
    # title page, "by Author" subtitle, Contents heading + TOC list,
    # and any repeated title/dedication, without misclassifying
    # "Letter 1" as front matter (it matches the chapter regex).
    headings = body.find_all(["h1", "h2", "h3"])
    first_chapter = _find_first_chapter_heading(headings)

    if first_chapter is None:
        # Fallback: no recognizable chapter heading. Drop only the
        # obvious front-matter tags by name and keep the rest as a
        # single page.
        _drop_front_matter_by_heading(body)
        chapters = [(None, body)]
    else:
        chapters = _split_into_chapters(body, first_chapter)

    pages: list[Page] = []
    toc: list[TocEntry] = []
    for idx, (chapter_title, container) in enumerate(chapters, start=1):
        md = _render_markdown(container)
        md = _post_clean(md)
        if not md.strip():
            continue
        pages.append(Page(no=idx, text=md, char_count=len(md)))
        if chapter_title:
            toc.append(TocEntry(level=1, title=chapter_title, page=idx))

    return LoadedHtml(
        pages=pages,
        toc=toc,
        title=title,
        author=author,
        subjects=subjects,
    )


# -----------------------------------------------------------------------
# Metadata
# -----------------------------------------------------------------------

def _read_metadata(soup: BeautifulSoup) -> tuple[str | None, str | None, list[str]]:
    def meta(name: str) -> str | None:
        tag = soup.find("meta", attrs={"name": name})
        if tag and tag.get("content"):
            return tag["content"].strip()
        return None

    title = meta("dc.title")
    author = meta("dc.creator")

    # Fallback for older Gutenberg files that don't carry `dc.title` /
    # `dc.creator` meta. The `<title>` tag follows the pattern
    # "The Project Gutenberg eBook of TITLE, by AUTHOR" and the first
    # `<h1>` is the bare title.
    if not title or not author:
        head_title = soup.title.string.strip() if soup.title and soup.title.string else None
        if head_title:
            t, a = _parse_pg_head_title(head_title)
            if not title and t:
                title = t
            if not author and a:
                author = a
    if not title:
        h1 = soup.find("h1")
        if h1 and h1.get_text(strip=True):
            title = h1.get_text(" ", strip=True)

    if author:
        # Gutenberg stores authors as "Shelley, Mary Wollstonecraft, 1797-1851".
        # Strip the date range and flip "Last, First" → "First Last".
        author = re.sub(r",\s*\d{3,4}-\d{0,4}\.?\s*$", "", author).strip()
        if "," in author:
            last, _, first = author.partition(",")
            author = f"{first.strip()} {last.strip()}".strip()
    else:
        # Last-resort fallback: a curated title→author map covers the
        # classics where the Gutenberg edition omitted dc.creator and
        # the head <title> doesn't carry "by AUTHOR" (e.g. the modern
        # `"Romeo and Juliet | Project Gutenberg"` shape). Without this
        # the FeedItem would byline the publisher identity instead of
        # the actual author.
        fallback = lookup_known_author(title)
        if fallback:
            author = fallback

    subjects: list[str] = []
    for tag in soup.find_all("meta", attrs={"name": "dc.subject"}):
        c = tag.get("content")
        if c:
            subjects.append(c.strip())

    return title, author, subjects


_PG_HEAD_RE = re.compile(
    r"^\s*The\s+Project\s+Gutenberg\s+(?:e[Bb]ook|EBook|ebook)\s+of\s+(?P<title>.+?)"
    r"(?:,\s*by\s+(?P<author>[^,]+?))?\s*$"
)


def _parse_pg_head_title(raw: str) -> tuple[str | None, str | None]:
    """Old Gutenberg HTML <title> tag: 'The Project Gutenberg eBook of
    TITLE, by AUTHOR'. Returns (title, author) — either may be None if
    the pattern doesn't match."""
    m = _PG_HEAD_RE.match(raw)
    if not m:
        return None, None
    return (
        (m.group("title") or "").strip() or None,
        (m.group("author") or "").strip() or None,
    )


# -----------------------------------------------------------------------
# Chapter discovery
# -----------------------------------------------------------------------

def _is_chapter_heading(tag: Tag) -> bool:
    if tag.name not in ("h1", "h2", "h3"):
        return False
    text = tag.get_text(" ", strip=True)
    if not text:
        return False
    if _CHAPTER_RE.match(text):
        return True
    # Prefer the numeral-with-title pattern over the bare numeral
    # pattern when both apply — but the check order doesn't actually
    # matter (both return True), only the doc-order pick in
    # `_find_first_chapter_heading` does, where the outer h2
    # "I. A SCANDAL IN BOHEMIA" will sort before the inner h3 "I.".
    if _LEADING_NUMERAL_TITLE_RE.match(text):
        return True
    if _NUMERAL_RE.match(text):
        return True
    return False


def _find_first_chapter_heading(headings: list[Tag]) -> Tag | None:
    for h in headings:
        if _is_chapter_heading(h):
            return h
    return None


def _drop_front_matter_by_heading(body: Tag) -> None:
    """Fallback path when no chapter heading is detected — best-effort
    removal of obvious front-matter sections by heading text."""
    for h in list(body.find_all(["h1", "h2", "h3"])):
        text = h.get_text(" ", strip=True).lower().rstrip(".:")
        if text in _FRONT_MATTER_HEADINGS:
            # Drop this heading and the next sibling block.
            sib = h.find_next_sibling()
            h.decompose()
            if sib and sib.name in ("ul", "ol", "table", "div", "p"):
                sib.decompose()


def _split_into_chapters(body: Tag, first_chapter: Tag) -> list[tuple[str, Tag]]:
    """Return [(chapter_title, container_soup), ...] starting at `first_chapter`.

    `container_soup` is a synthetic <div> holding all elements between
    one chapter heading and the next (exclusive). The heading itself is
    kept inside the container so the chapter title shows up in the
    rendered markdown as `# Chapter N`.
    """
    # Build a flat list of body's direct children that we'll scan.
    # Use descendants from body, but only top-level so we keep DOM order.
    elements = [el for el in body.descendants if isinstance(el, Tag)]

    # Find indices of every chapter-pattern heading at any depth.
    chapter_indices: list[int] = []
    for i, el in enumerate(elements):
        if _is_chapter_heading(el):
            chapter_indices.append(i)
    if not chapter_indices:
        return []

    # Walk the body's direct children, skipping anything before the
    # first chapter heading. We work at the *direct child* level —
    # body→child→…→h2 means we skip the parent container only if it
    # has no chapter heading inside it. Simpler: linearize the body
    # by splitting on chapter headings via a DOM walk.
    chapters: list[tuple[str, Tag]] = []

    # Strategy: re-walk body in document order; collect everything
    # between two chapter headings into a fresh container.
    soup = BeautifulSoup("<div></div>", _BS4_PARSER)
    current_title: str | None = None
    current_container: Tag | None = None
    started = False

    def _start_new(heading: Tag) -> None:
        nonlocal current_title, current_container
        title = heading.get_text(" ", strip=True)
        # Normalize internal whitespace from <br> tags etc.
        title = re.sub(r"\s+", " ", title)
        current_title = title
        current_container = soup.new_tag("div")
        # Preserve heading inside the container so markdown renders it
        # as a chapter title.
        h_clone = soup.new_tag("h2")
        h_clone.string = title
        current_container.append(h_clone)
        chapters.append((title, current_container))

    # Use a flat document-order iteration of *non-nested* nodes. We
    # iterate body.descendants but skip nodes whose ancestors we've
    # already accepted into a chapter — easier: only take elements
    # whose .parent is body. Most Gutenberg books are flat under body.
    # When a chapter heading is found, switch container.
    for child in list(body.children):
        if isinstance(child, Comment):
            # `<!--end chapter-->` etc. — Gutenberg uses these between
            # chapter divs. Drop silently.
            continue
        if isinstance(child, NavigableString):
            if started and current_container is not None:
                # bare text under body → wrap in a paragraph
                if str(child).strip():
                    p = soup.new_tag("p")
                    p.string = str(child)
                    current_container.append(p)
            continue
        if not isinstance(child, Tag):
            continue

        # If this child contains a chapter heading at any depth, we may
        # need to split inside it. Most PG books have flat <h2> + <p>
        # at body level, so the common path is just: child IS the h2.
        if _is_chapter_heading(child):
            _start_new(child)
            started = True
            continue

        # Look for chapter headings *inside* a wrapper div (some books
        # wrap each chapter in <div class="chapter">…</div> with the
        # h2 nested one level down).
        nested = child.find(["h1", "h2", "h3"])
        if nested is not None and _is_chapter_heading(nested):
            _start_new(nested)
            started = True
            for sib in list(child.children):
                if isinstance(sib, Tag) and sib is nested:
                    continue
                if current_container is not None:
                    if isinstance(sib, Tag):
                        current_container.append(sib.extract())
                    elif isinstance(sib, NavigableString) and str(sib).strip():
                        p = soup.new_tag("p")
                        p.string = str(sib)
                        current_container.append(p)
            continue

        if started and current_container is not None:
            current_container.append(child.extract() if hasattr(child, "extract") else child)

    return chapters


# -----------------------------------------------------------------------
# HTML → Markdown (lightweight, custom — no markdownify dep)
# -----------------------------------------------------------------------

_BLOCK_TAGS = {"p", "div", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "li", "hr"}


def _render_markdown(node: Tag) -> str:
    out: list[str] = []
    _render(node, out)
    return "".join(out)


def _render(node, out: list[str]) -> None:
    # Comment is a NavigableString subclass — filter before the text path
    # so `<!--end chapter-->` doesn't render as the literal phrase.
    if isinstance(node, Comment):
        return
    if isinstance(node, NavigableString):
        out.append(str(node))
        return
    if not isinstance(node, Tag):
        return

    name = node.name
    if name in ("script", "style", "link", "meta", "noscript"):
        return

    if name == "br":
        out.append("\n")
        return

    if name == "hr":
        out.append("\n\n* * *\n\n")
        return

    if name in ("em", "i"):
        out.append("*")
        for c in node.children:
            _render(c, out)
        out.append("*")
        return

    if name in ("strong", "b"):
        out.append("**")
        for c in node.children:
            _render(c, out)
        out.append("**")
        return

    if name == "blockquote":
        # Render inner, then prefix every non-empty line with "> "
        inner: list[str] = []
        for c in node.children:
            _render(c, inner)
        text = "".join(inner).strip("\n")
        quoted = "\n".join(("> " + ln) if ln.strip() else ">"
                           for ln in text.splitlines())
        out.append("\n\n" + quoted + "\n\n")
        return

    if name in ("h1", "h2", "h3", "h4", "h5", "h6"):
        level = int(name[1])
        out.append("\n\n" + "#" * level + " ")
        for c in node.children:
            _render(c, out)
        out.append("\n\n")
        return

    if name == "p":
        out.append("\n\n")
        for c in node.children:
            _render(c, out)
        out.append("\n\n")
        return

    if name in ("ul", "ol"):
        # Most PG TOCs are already stripped; this handles the rare
        # in-body list (e.g. a list of dramatis personae).
        out.append("\n")
        for li in node.find_all("li", recursive=False):
            out.append("- ")
            for c in li.children:
                _render(c, out)
            out.append("\n")
        out.append("\n")
        return

    if name == "a":
        # Drop links — Gutenberg uses them only for internal anchors.
        for c in node.children:
            _render(c, out)
        return

    if name == "img":
        # Drop original Gutenberg illustrations — pipeline generates new ones.
        return

    # Default: pass-through for span / div / section etc.
    for c in node.children:
        _render(c, out)


# -----------------------------------------------------------------------
# Post-render cleanup
# -----------------------------------------------------------------------

_MULTIPLE_BLANK = re.compile(r"\n{3,}")
_TRAILING_WS = re.compile(r"[ \t]+\n")
_INTERNAL_WS = re.compile(r"[ \t]{2,}")


def _post_clean(md: str) -> str:
    md = _TRAILING_WS.sub("\n", md)
    md = _INTERNAL_WS.sub(" ", md)
    md = _MULTIPLE_BLANK.sub("\n\n", md)
    return md.strip() + "\n"
