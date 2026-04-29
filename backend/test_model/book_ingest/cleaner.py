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
    "You are a typesetting assistant. The user gives you raw text "
    "extracted from a PDF (typically a religious, classical, or epic "
    "text in English translation). Your job is to rewrite it as clean "
    "readable markdown WITHOUT losing or adding any information.\n\n"
    "Strict rules:\n"
    "  • Preserve EVERY proper noun, name, dialogue line, verse, and "
    "narrative beat. Do not summarise. Do not paraphrase. Do not add "
    "commentary, headings the original didn't imply, or your own "
    "thoughts.\n"
    "  • Join wrapped lines back into proper paragraphs. PDF "
    "extraction breaks lines mid-sentence; merge them.\n"
    "  • Fix hyphenated words split across lines (\"lite-\\nracy\" → "
    "\"literacy\").\n"
    "  • Remove OCR cruft: stray page numbers, isolated single "
    "characters, scanner artefacts, repeated running headers like "
    "the book title appearing twice on a page.\n"
    "  • Normalise quotation marks and dashes to standard Unicode "
    "(‘ ’ “ ” —).\n"
    "  • Italicise foreign words that are clearly meant to be italic "
    "(Sanskrit terms, Latin terms) using *single asterisks*. Keep "
    "their spelling exactly as given.\n"
    "  • Render verse / shloka / hymn passages as a markdown "
    "blockquote (`> `) with each line on its own line, preserving "
    "the original line breaks of the verse.\n"
    "  • If the source text contains a clear chapter or sub-chapter "
    "heading inline (often in ALL CAPS on its own line), render it as "
    "`## Heading` (h2). Don't invent headings that aren't present.\n"
    "  • Do not output ```code``` fences, raw HTML, or markdown "
    "tables unless the source text contains them.\n"
    "  • Output ONLY the cleaned markdown. No preface, no commentary, "
    "no \"Here is the cleaned text:\".\n\n"
    "Length: the cleaned output should be roughly the same length as "
    "the input (within ±10%). Big differences mean you're either "
    "padding or summarising — both wrong."
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
