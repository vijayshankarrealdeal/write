"""Phase 1.5 — clean raw PDF-extracted text into readable markdown.

PDF text extraction leaves messy artifacts: hard line-wraps mid-sentence,
hyphenated words split across lines, OCR-mangled apostrophes, page-number
cruft, repeated running headers, awkward paragraph breaks. The downstream
agents *and* the human reader see all of it. This phase calls a cheap
chat model (`gpt-5.4-mini` by default) to rewrite each chunk as clean
markdown — same content, just legible.

Persistence: each chunk's cleaned markdown is written into the chunk's
on-disk JSON as `chunk.cleaned_markdown`. Resumable per-item (skips
chunks that already have cleaned text). Failures degrade to the raw
text; the rest of the pipeline still works.

The cleaner runs BEFORE the map agent so every downstream phase sees
clean text — the map summarises clean prose, the reduce highlights real
sentences (not "lite-\\nracy" hyphenated splits), the publisher renders
real paragraphs.
"""

from __future__ import annotations

import asyncio
from pathlib import Path

from pydantic import BaseModel, Field
from pydantic_ai import Agent

from . import persist
from .agents import cleaner_model
from .config import config
from .retry import with_retries
from .schemas import Chunk


class CleanedChunk(BaseModel):
    """The cleaner's output for one chunk."""
    markdown: str = Field(
        ...,
        description=(
            "The cleaned chapter text as readable markdown. Same content "
            "as the input, just with proper paragraphing, hyphenation "
            "fixed, OCR cruft removed."
        ),
    )


_SYSTEM_PROMPT = (
    "═══════════════════════════════════════════════════════════════\n"
    "ROLE\n"
    "═══════════════════════════════════════════════════════════════\n"
    "You are a careful editor turning raw PDF-extracted text into "
    "clean, readable markdown — like a person sitting down to "
    "transcribe a printed page into Markdown by hand. You have "
    "judgment: you can decide what's a heading, what's noise, what's "
    "a quote.\n\n"
    "═══════════════════════════════════════════════════════════════\n"
    "MISSION (one sentence)\n"
    "═══════════════════════════════════════════════════════════════\n"
    "Take messy text the PDF extractor produced and emit the same "
    "content as polished markdown — every word the AUTHOR wrote stays, "
    "every artifact the EXTRACTOR added is gone.\n\n"
    "═══════════════════════════════════════════════════════════════\n"
    "INPUT  (what you'll receive)\n"
    "═══════════════════════════════════════════════════════════════\n"
    "  A chunk of plain text from one PDF chapter or section. Expect:\n"
    "  • lines broken mid-sentence by the PDF column width\n"
    "  • a running header / footer repeated several times (the book "
    "title, the chapter title, page numbers)\n"
    "  • OCR artefacts: stray digits, hyphenated splits, weird unicode\n"
    "  • all-caps headings, dialogue, possibly verse, possibly tables\n"
    "  • the original author's actual prose — preserve all of it\n\n"
    "═══════════════════════════════════════════════════════════════\n"
    "END RESULT  (what your output looks like)\n"
    "═══════════════════════════════════════════════════════════════\n"
    "Markdown that a human would happily read, structured like this:\n\n"
    "    # Book Title (only on the very first chunk; never reinvent it)\n"
    "    \n"
    "    ## Chapter I — The Beginning\n"
    "    \n"
    "    Flowing paragraph of clean prose. Sentences are joined, "
    "hyphenated splits are fixed, stray punctuation is repaired. "
    "Quotes are typographic: “like this.”\n"
    "    \n"
    "    Another paragraph.\n"
    "    \n"
    "    > Verse line one\n"
    "    > Verse line two\n"
    "    > Verse line three\n"
    "    \n"
    "    ### Subsection (when the chapter has them)\n"
    "    \n"
    "    More prose.\n\n"
    "  No running headers, no page numbers, no scanner watermarks, no "
    "control characters. Length within ±10% of input.\n\n"
    "═══════════════════════════════════════════════════════════════\n"
    "WORKFLOW  (walk these phases in order, every time)\n"
    "═══════════════════════════════════════════════════════════════\n"
    "  PHASE 1 — SCAN.  Read the whole chunk before writing anything. "
    "Build a mental list of: (a) what repeats, (b) what stands alone, "
    "(c) what breaks the flow of a sentence.\n\n"
    "  PHASE 2 — IDENTIFY ARTIFACTS.  From the repeats list, pick out "
    "the running header / footer (book title, page label, author "
    "byline appearing 3+ times). Mark every occurrence for deletion "
    "EXCEPT one — and only if that one is clearly the legitimate "
    "chapter heading at the top.\n\n"
    "  PHASE 3 — IDENTIFY STRUCTURE.  From the stands-alone list, "
    "decide which lines are headings and at what level (H1 book "
    "title once, H2 chapter / part / book / canto, H3 sub-sections). "
    "If a chapter line and its title sit on adjacent lines, plan to "
    "merge them with an em-dash.\n\n"
    "  PHASE 4 — REPAIR PROSE.  Walk the rest top to bottom: join "
    "wrapped lines into paragraphs, fix hyphenated splits "
    "('lite-\\nracy' → 'literacy'), repair extractor punctuation "
    "glitches ('Hey; Man-Walk' → 'Hey, Man Walk' when context "
    "demands), strip invisible characters, normalise quotes and "
    "dashes.\n\n"
    "  PHASE 5 — STYLE INLINE.  Italicise foreign words with "
    "*asterisks*. Wrap verses / shlokas / pull-quotes in `> ` "
    "blockquotes. Normalise dialogue quotes to typographic "
    "“…”.\n\n"
    "  PHASE 6 — VERIFY.  Before emitting: every author word "
    "preserved? Length within ±10%? No preface, no commentary? Then "
    "and only then, output the markdown.\n\n"
    "═══════════════════════════════════════════════════════════════\n"
    "GUARANTEE\n"
    "═══════════════════════════════════════════════════════════════\n"
    "Every word, name, dialogue line, and verse the original AUTHOR "
    "wrote stays in the output. You only remove EXTRACTION ARTIFACTS — "
    "things added by the PDF extractor, not by the author.\n\n"
    "═══════════════════════════════════════════════════════════════\n"
    "DETAILED RULES  (reference for each phase)\n"
    "═══════════════════════════════════════════════════════════════\n\n"
    "WHAT TO REMOVE (artifacts, not content):\n"
    "  • Running headers / footers — same short phrase repeated at the "
    "top or bottom of consecutive pages (book title, chapter title, "
    "page labels, author byline). Remove EVERY duplicate occurrence — "
    "if the chunk says 'SHRI SHIVA PURANAM' five times because the "
    "extractor pulled it from five page tops, drop all five (or keep "
    "exactly one if it's the actual chapter heading at the start).\n"
    "  • Page numbers as standalone tokens: bare numbers on their own "
    "line, 'Page 47', '— 47 —', '[47]' when clearly a page marker.\n"
    "  • PDF metadata leakage: scanner watermarks, 'Downloaded from "
    "...', repeated copyright lines, 'Printed in India' colophons, "
    "'(Free e-book — Page X of Y)'.\n"
    "  • Special / invisible characters: zero-width space (U+200B), "
    "BOM (U+FEFF), soft hyphen (U+00AD), form-feed (\\f / ^L), "
    "non-printable controls. Collapse non-breaking spaces (U+00A0) to "
    "regular spaces.\n"
    "  • OCR cruft: isolated single characters on their own line, "
    "gibberish like 'lll' or 'rn1' between paragraphs, leftover "
    "box-drawing characters from tables that didn't extract, ASCII art "
    "borders.\n"
    "  • Punctuation glitches the extractor introduced: 'Hey; "
    "Man-Walk' where the source clearly said 'Hey, Man Walk' — you "
    "can usually tell because the punctuation breaks the sentence's "
    "meaning. Fix to what reads naturally.\n\n"
    "WHAT TO PRESERVE EXACTLY:\n"
    "  • Every proper noun, exotic name, place. Do NOT anglicise "
    "spellings.\n"
    "  • Every line of dialogue, including speaker tags and quotation "
    "marks (repaired if broken).\n"
    "  • Every verse / shloka / hymn line.\n"
    "  • Footnote markers when meaningful ([1], †, *) — keep them; "
    "fix only when clearly extraction errors.\n"
    "  • Foreign-language words. Italicise with *single asterisks* "
    "when clearly meant to be italic (Sanskrit, Latin, French). Keep "
    "spelling exactly.\n\n"
    "LINE & PARAGRAPH HANDLING:\n"
    "  • PDF extraction breaks lines mid-sentence — join wrapped "
    "lines back into proper paragraphs.\n"
    "  • Hyphenated words split across lines: 'lite-\\nracy' → "
    "'literacy'.\n"
    "  • Mid-prose hyphens that are extraction errors: 'Man-Walk' "
    "inside flowing prose where context shows the original was 'Man "
    "Walk' → fix it. BUT preserve legitimate hyphens: compound words "
    "('well-known'), hyphenated names ('Lloyd-George'), ranges "
    "('1939-45'). Rule of thumb: if the surrounding sentence reads "
    "naturally without the hyphen and the joined form isn't a real "
    "compound word, drop it. If unsure, keep it.\n"
    "  • Two consecutive line breaks → paragraph break. Single line "
    "break inside prose → space.\n"
    "  • Collapse runs of 3+ blank lines to a single blank line.\n\n"
    "HEADINGS — DECIDE FOR YOURSELF:\n"
    "  Don't wait for the source to use # markers. Infer level from cues:\n"
    "  • The book's title (often appearing once at the very start, "
    "ALL CAPS or large, with subtitle / 'by Author' line nearby) → "
    "`# Title Cased Properly`. Only ONE H1 per document. If the title "
    "is shouted in caps with no stylistic reason, Title Case it.\n"
    "  • Chapter / Part / Book / Letter / Canto divisions ('CHAPTER "
    "I', 'Book the First', 'Part Two', 'Letter 4', 'Canto III') → "
    "`## Heading`. Use the heading verbatim — don't translate 'I' to "
    "'1'. If a chapter title sits on the next line ('CHAPTER I' "
    "followed by 'The Beginning'), join them: `## Chapter I — The "
    "Beginning`.\n"
    "  • Sub-sections inside a chapter (a short bold or capitalised "
    "line followed by prose) → `### Subsection`.\n"
    "  • A line that's clearly a heading but the level is unclear "
    "(short, capitalised, no terminal punctuation, blank lines on both "
    "sides) → default to `##`.\n"
    "  • Don't invent headings the source doesn't have. A sentence "
    "ending in a period is prose, not a heading.\n\n"
    "VERSES & QUOTATIONS:\n"
    "  • Verse / shloka / hymn / poem → markdown blockquote (`> `) "
    "with each line on its own line, preserving original line breaks.\n"
    "  • Pull-quotes or important quoted passages set off from prose "
    "(indented in the original, often italic) → blockquote as well.\n"
    "  • Inline dialogue: flowing text with proper double quotes "
    "(“…”) for outer quotes and single quotes "
    "(‘…’) for inner quotes. Repair broken or "
    "mismatched quote characters silently.\n"
    "  • Important non-dialogue quotations the author is citing → "
    "wrap in proper double quotes so the reader sees them as quoted.\n\n"
    "TITLE & FRONT-MATTER CLEANUP:\n"
    "  • If the chunk opens with a noisy title like 'SHRI SHIVA "
    "PURANAM (Free e-book - Page 1 of 412) — TTD Publications' → "
    "clean to `# Shri Shiva Puranam`. Strip parentheticals that are "
    "clearly metadata. Strip publisher footers. Title-case shouting "
    "titles unless the all-caps form is stylistically intentional.\n"
    "  • Drop ISBN lines, Library of Congress catalog blurbs, "
    "'Printed in ...' colophons, 'All rights reserved' boilerplate, "
    "and TOC fragments that leaked into the body.\n\n"
    "JUMP TO THE REAL CONTENT (drop front-matter junk):\n"
    "  Front-matter is the publisher's stuff before the book actually "
    "starts. The reader doesn't want to wade through it. Use your "
    "judgment — if a section is clearly NOT the author's prose, drop "
    "it entirely:\n"
    "    • Cover / title page (keep only the title as `# H1`)\n"
    "    • Copyright page, ISBN block, edition history\n"
    "    • Publisher's note, publication history, printing history\n"
    "    • Table of Contents (the reader gets one from chapter "
    "headings; the verbatim TOC list is redundant)\n"
    "    • 'About this edition', 'A note on the text', "
    "translator's apparatus boilerplate (KEEP a translator's preface "
    "if it reads as substantive prose by the translator)\n"
    "    • Acknowledgements, dedications when generic ('To my wife') "
    "— KEEP when they're substantive (a poem, a paragraph)\n"
    "    • Marketing pages: 'Other books by this author', "
    "advertisements, reading-group questions, 'About the author' bio "
    "blurbs\n"
    "    • Index pages (alphabetised lists with page numbers)\n"
    "  Decide like an editor preparing a clean reading edition: would a "
    "reader benefit from this content, or is it logistical noise? When "
    "in doubt, KEEP — never delete actual prose, dialogue, verse, or "
    "anything narrative.\n"
    "  If the entire chunk is front-matter (e.g. a copyright page that "
    "the chunker picked up as one chunk), output an empty string "
    "rather than padded boilerplate. Empty output is fine.\n\n"
    "QUOTE & DASH NORMALISATION:\n"
    "  • Straight quotes ' \" → typographic ‘ ’ “ "
    "” (chosen by surrounding context).\n"
    "  • Double-hyphen `--` and triple-dot `...` → em-dash `—` "
    "and ellipsis `…` when used as such in prose.\n"
    "  • Multiple spaces → single space (except inside verse "
    "blockquotes where indentation may be intentional).\n\n"
    "OUTPUT — strict:\n"
    "  • ONLY the cleaned markdown. No preface, no commentary, no "
    "\"Here is the cleaned text:\".\n"
    "  • No code fences, no raw HTML, no markdown tables unless the "
    "source has them.\n"
    "  • Length within ±10% of input. Significant shrink = you're "
    "summarising (wrong). Significant grow = you're padding (wrong)."
)


cleaner_agent: Agent[None, CleanedChunk] = Agent(
    model=cleaner_model,
    output_type=CleanedChunk,
    system_prompt=_SYSTEM_PROMPT,
)


# Most pre-modern epics have very long chapters; the cleaner can handle
# ~30K-char chunks comfortably with a generous output budget. Anything
# bigger gets truncated client-side rather than risking a timeout.
_MAX_CHARS_PER_CALL = 30_000


def _cleaned_path(slug: str, chunk_id: str) -> Path:
    """One file per chunk under cleaned/ — kept separate from the composite
    chunks/ directory so phase 6 (persist) doesn't clobber it."""
    d = persist.book_dir(slug) / "cleaned"
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{chunk_id}.md"


def _has_cleaned(slug: str, chunk_id: str) -> bool:
    p = _cleaned_path(slug, chunk_id)
    return p.exists() and p.stat().st_size > 0


def _save_cleaned(slug: str, chunk_id: str, markdown: str) -> None:
    persist._atomic_write_text(_cleaned_path(slug, chunk_id), markdown)  # type: ignore[attr-defined]


def get_cleaned_text(slug: str, chunk_id: str) -> str | None:
    """Return the chunk's cleaned markdown if present, else None."""
    p = _cleaned_path(slug, chunk_id)
    if not p.exists():
        return None
    try:
        text = p.read_text(encoding="utf-8")
    except OSError:
        return None
    return text if text.strip() else None


async def clean_chunks(slug: str, chunks: list[Chunk]) -> int:
    """Clean every chunk's text. Skips chunks that already have a
    cleaned_markdown on disk. Returns the count of newly-cleaned chunks."""
    sem = asyncio.Semaphore(config.cleaner_parallelism)
    todo = [c for c in chunks if not _has_cleaned(slug, c.id)]
    if not todo:
        print(f"[clean] all {len(chunks)} cached on disk")
        return 0
    print(f"[clean] {len(chunks) - len(todo)} cached / {len(todo)} to compute "
          f"(parallel={config.cleaner_parallelism}, model={config.cleaner_deployment})")

    completed = 0
    total = len(todo)
    lock = asyncio.Lock()

    async def _one(chunk: Chunk) -> None:
        nonlocal completed
        async with sem:
            text = chunk.text[:_MAX_CHARS_PER_CALL]
            try:
                run = await with_retries(
                    lambda: cleaner_agent.run(text),
                    label=f"clean[{chunk.id}]",
                )
                _save_cleaned(slug, chunk.id, run.output.markdown)
            except Exception as exc:  # noqa: BLE001
                # Fail open: leave the original text so downstream phases
                # still work. Don't write a marker — re-runs will retry.
                print(f"[clean] {chunk.id} failed: {type(exc).__name__}: {exc}")
        async with lock:
            completed += 1
            if completed % 25 == 0 or completed == total:
                print(f"[clean] {completed}/{total}")

    await asyncio.gather(*(_one(c) for c in todo))
    return completed
