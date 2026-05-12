"""Strip front-matter / boilerplate from PDF-extracted text.

Public-domain digitizations of long-form classics (Mahābhārata,
Ramayana, Bible, Plato, etc.) are riddled with non-content pages that
don't belong in the published reader:

  - Translator's prefaces and apologia
  - Scanner / proofer attribution ("Scanned at sacred-texts.com…")
  - Project Gutenberg / Internet Archive licence boilerplate
  - Half-titles and full title pages
  - Translator/editor biographies
  - Long copyright + edition-history blocks

A minute fraction of these would survive a manual edit, but the LLM
pipeline doesn't need to read or pay tokens to summarise them, and
readers definitely don't want SECTION 1 of the Mahābhārata to be a
1880s translator's methodology essay.

We use two cheap detectors (no LLM):

1. **Boilerplate-line stripper** — drop individual lines that match a
   curated regex set. Keeps the rest of the chunk intact.
2. **Whole-chunk dropper** — if the *remaining* text after stripping is
   still mostly-front-matter (high keyword density, low narrative
   markers), the chunk gets dropped from the chunker output.

Tune the patterns by adding lines you spot in real ingests; they're
intentionally conservative so legitimate body text isn't damaged.
"""

from __future__ import annotations

import re

# Lines that match any of these are dropped outright. Keep them line-
# anchored — we don't want to strip a paragraph that happens to mention
# the word "translator" mid-sentence in the actual narrative.
_LINE_PATTERNS = [
    re.compile(p, re.IGNORECASE)
    for p in (
        r"^\s*scanned\s+at\s+\S+",
        r"^\s*proofed\s+(?:at|by)\b",
        r"^\s*distributed\s+proofing\b",
        r"^\s*sacred-?texts\.com\b",
        r"^\s*project\s+gutenberg\b.*",
        r"^\s*the\s+project\s+gutenberg\s+(?:e?book|literary\s+archive)",
        r"^\s*\*+\s*end\s+of\s+(?:the\s+)?project\s+gutenberg",
        r"^\s*\*+\s*start\s+of\s+(?:the\s+)?project\s+gutenberg",
        r"^\s*(?:internet|archive)\s+archive\.?org\b",
        r"^\s*all\s+rights\s+reserved\.?\s*$",
        r"^\s*copyright\s+(?:\(c\)|©)?\s*\d{4}\b",
        r"^\s*©\s*\d{4}\b",
        # Bracketed "[Copyright YYYY by X.]" lines that sit under
        # illustration captions in 19th-century Gutenberg HTML
        # (e.g. the Hugh Thomson edition of Pride and Prejudice).
        # Markdown rendering wraps the italic in asterisks, hence
        # the optional `\*` after the opening bracket.
        r"^\s*\[?\s*\*?\s*copyright\s+\d{4}\s+by\b.*?\*?\s*\]?\s*$",
        r"^\s*\[?\s*\*?\s*illustration\s*[:.]?\s*\*?\s*\]?\s*$",
        r"^\s*first\s+published\s+\d{4}\b",
        r"^\s*reprinted\s+\d{4}\b",
        r"^\s*by\s+j\.\s*b\.\s*hare\b",
        r"^\s*additional\s+(?:proofing|formatting)\b",
        r"^\s*translated\s+(?:into\s+english\s+)?prose\s+from\s+the\s+original\s+sanskrit",
        # Standalone delimiter / page-number cruft
        r"^\s*page\s+\d+\s+of\s+\d+\s*$",
        r"^\s*-\s*\d+\s*-\s*$",
        r"^\s*\f\s*$",
    )
]

# Headers that mark a *whole section* of front-matter or back-matter.
# We also drop any chunk whose text starts with one of these and lacks
# a real-narrative marker further down.
_SECTION_HEADERS = re.compile(
    r"^\s*(translator'?s?\s+preface|preface|"
    r"foreword|introduction\b\s*$|"
    r"editor'?s?\s+(note|preface|foreword)|"
    r"scanner'?s?\s+notes|"
    r"about\s+(?:the\s+)?(?:author|translator|editor)|"
    r"acknowledg(?:e?ments?|ements?)|"
    r"dedication\s*$|"
    r"colophon\s*$|"
    # Back matter
    r"glossary\b\s*$|"
    r"bibliography\b\s*$|"
    r"index\b\s*$|"
    r"contents\b\s*$|"
    r"table\s+of\s+contents\b\s*$|"
    # Volume dividers (very common in multi-volume reprints — they're
    # 1-page section breaks with no actual narrative content).
    r"volume\s+[ivx\d]+\b)",
    re.IGNORECASE | re.MULTILINE,
)

# Strong indicators that the chunk is body text, not front-matter.
# A chunk that has front-matter signals AND one of these likely is the
# first real chapter; we keep it.
_BODY_MARKERS = re.compile(
    r"\b(chapter|section|book)\s+(?:i{1,3}v?|iv|v|vi{0,3}|ix|x|xi{0,3}|"
    r"\d+|one|two|three|four|five|six|seven|eight|nine|ten)\b",
    re.IGNORECASE,
)

# Short-circuit: if these keywords dominate, treat the chunk as front-matter.
_FRONTMATTER_KEYWORDS = (
    "translator", "preface", "scanned", "proofed", "copyright",
    "all rights", "edition", "publisher", "edited by", "fasciculus",
    "first published",
)

# Smoking-gun phrases that ALWAYS mark the chunk as front-matter, even
# when it happens to contain a "BOOK 1 / SECTION I" label (which often
# appears on the same page as the translator's preface).
_DEFINITELY_FRONT_MATTER = re.compile(
    r"(translator'?s?\s+preface|"
    r"scanned\s+at\s+\S+|"
    r"proofed\s+(?:at|by)\s+\S+|"
    r"distributed\s+proofing|"
    r"additional\s+(?:proofing|formatting)|"
    r"sacred-?texts\.com|"
    r"project\s+gutenberg|"
    r"published\s+by\s+pratapa|"
    r"object\s+of\s+a\s+translator|"
    # TTD / Indian-publishing boilerplate (Siva Puranam, etc.)
    r"t\.?t\.?d\.?\s*religious\s+publications|"
    r"tirumala\s+tirupati\s+devasthanams?|"
    r"published\s+by\s+sri\s+\S+\s+i\.?a\.?s\.?|"
    r"executive\s+officer\b.*devasthan|"
    r"printed\s+at\s+t\.?t\.?d\.?\s*press|"
    r"religious\s+publications\s+series\s+no\.?\s*\d+|"
    r"©\s*all\s+rights\s+reserved|"
    r"first\s+edition\s*[:\.]\s*\d{4})",
    re.IGNORECASE,
)


def strip_boilerplate_lines(text: str) -> str:
    """Remove individual boilerplate lines, keep the rest."""
    if not text:
        return text
    out: list[str] = []
    for line in text.splitlines():
        if any(p.search(line) for p in _LINE_PATTERNS):
            continue
        out.append(line)
    return "\n".join(out)


def looks_like_front_matter(text: str) -> bool:
    """True when the chunk is mostly preface / boilerplate. Conservative
    — only fires on chunks where front-matter signals are dense AND
    body markers (chapter / section labels) are absent, OR when a
    smoking-gun phrase like 'Translator's Preface' / 'Scanned at …'
    appears anywhere in the chunk (those override body markers because
    title pages and prefaces routinely embed a 'BOOK 1' header)."""
    if not text:
        return True

    sample = text[:6000].lower()  # cap work on giant chunks

    # Strong: smoking-gun phrase appears anywhere in the chunk.
    if _DEFINITELY_FRONT_MATTER.search(sample):
        return True

    # Strong: first non-empty line is a known front-matter section header.
    first = next((ln for ln in sample.splitlines() if ln.strip()), "")
    starts_with_header = bool(_SECTION_HEADERS.match(first))

    # Keyword density.
    hits = sum(sample.count(k) for k in _FRONTMATTER_KEYWORDS)
    has_body = bool(_BODY_MARKERS.search(sample))

    if starts_with_header and not has_body:
        return True
    if hits >= 4 and not has_body and len(sample) < 12000:
        return True
    return False


def clean_chunk_text(text: str) -> str:
    """Strip boilerplate lines + collapse runs of blank lines. Returns
    cleaned text suitable for the map/reduce agents."""
    cleaned = strip_boilerplate_lines(text)
    # Collapse 3+ blank lines down to 1; keeps paragraph breaks intact.
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
    return cleaned.strip()


def strip_running_headers(pages_text: list[str]) -> list[str]:
    """Detect short lines that recur on the first or last position of
    many pages and strip them — typical PDF running headers/footers
    like the book title repeated atop every page.

    Conservative: only fires on lines that are short (< 80 chars), not
    pure digits (preserves real first lines like '1'), and appear on
    at least 30% of pages with text.
    """
    from collections import Counter

    n = sum(1 for t in pages_text if t and t.strip())
    if n < 6:
        # Too few pages to detect reliably — skip.
        return pages_text

    first = Counter()
    last = Counter()
    for t in pages_text:
        lines = [ln.strip() for ln in (t or "").splitlines() if ln.strip()]
        if not lines:
            continue
        if len(lines[0]) < 80 and not lines[0].isdigit():
            first[lines[0]] += 1
        if lines and len(lines[-1]) < 80 and not lines[-1].isdigit():
            last[lines[-1]] += 1

    threshold = max(3, int(n * 0.30))
    headers = {ln for ln, c in first.items() if c >= threshold}
    footers = {ln for ln, c in last.items() if c >= threshold and ln not in headers}

    if not headers and not footers:
        return pages_text

    out: list[str] = []
    for t in pages_text:
        lines = (t or "").splitlines()
        # Strip leading running header (may repeat — title twice on the page)
        while lines and lines[0].strip() in headers:
            lines.pop(0)
        while lines and lines[-1].strip() in footers:
            lines.pop()
        out.append("\n".join(lines))
    return out
