"""Phase 1.5 — scout agent that *reads the book* and proposes the visual
voice for the rest of the pipeline.

Why this exists: the user shouldn't have to know that the Mahābhārata
deserves "Indian classical miniature, vermilion and gold" while The
Prophet wants "watercolor, soft sepia." The chat model already has both
the cultural fluency and the actual text, so it can decide.

This is a single short LLM call (~1K input tokens, <500 out) that runs
once per book and is cached to `manifest.scout`. Cost is negligible
compared to the rest of the pipeline.
"""

from __future__ import annotations

from pydantic import BaseModel, Field
from pydantic_ai import Agent

from .agents import reduce_model  # use the smarter model — only one call
from .schemas import Chunk


class BookProposal(BaseModel):
    """The scout's recommendation for how to ingest this specific book."""
    detected_genre: str = Field(
        ...,
        description="One short phrase: 'Hindu epic in English translation', 'Victorian gothic novel', 'modern thriller', etc.",
    )
    cultural_context: str | None = Field(
        None,
        description="If the book has a strong cultural/period anchor that should shape illustrations, name it. Else null.",
    )
    suggested_style: str = Field(
        ...,
        description=(
            "A vivid art-direction string suitable to append to every image "
            "prompt. Should specify medium, palette, and rendering choices. "
            "Examples: 'Indian classical miniature painting, vermilion and "
            "gold, intricate detail', 'Ravi Varma oleograph style, dramatic "
            "lighting', 'Renaissance fresco, warm earth tones', 'graphite "
            "and ink wash, monochrome, sparse'."
        ),
    )
    suggested_reader_preference: str | None = Field(
        None,
        description=(
            "Optional steering for which moments to favor for illustration "
            "(e.g. 'epic battle scenes and divine encounters over domestic "
            "scenes'). null when the default coverage is fine."
        ),
    )
    suggested_image_budget: int = Field(
        ...,
        ge=10, le=120,
        description=(
            "Recommended number of illustrations for this book given its "
            "length and density of illustration-worthy moments. Long epics "
            "warrant more; tight novels fewer."
        ),
    )
    rationale: str = Field(
        ...,
        description="One or two sentences explaining the choices above so the user can sanity-check.",
    )


_SCOUT_SYSTEM = (
    "You are an art director surveying a book before it gets illustrated. "
    "You receive the book's title, page count, chunk count, and short "
    "samples from the start, middle, and end. Decide:\n"
    "  - genre + cultural context\n"
    "  - the single best illustration style for this specific book "
    "(don't default to 'editorial illustration')\n"
    "  - whether to bias scene picks toward any particular type of moment\n"
    "  - how many illustrations the book deserves\n"
    "Be specific and confident. The style string you return will be appended "
    "verbatim to every image prompt, so make it vivid."
)


_scout_agent: Agent[None, BookProposal] = Agent(
    model=reduce_model,
    output_type=BookProposal,
    system_prompt=_SCOUT_SYSTEM,
)


def _sample_text(chunks: list[Chunk], *, max_chars_per_sample: int = 4000) -> str:
    """Pull a head/middle/tail sample so the scout sees the book's voice
    without paying for the whole text. Keeps this call cheap."""
    if not chunks:
        return ""

    def _from_chunk(c: Chunk) -> str:
        return c.text[:max_chars_per_sample]

    head = chunks[0]
    tail = chunks[-1]
    mid = chunks[len(chunks) // 2]
    parts: list[str] = []
    seen: set[str] = set()
    for label, c in (("HEAD", head), ("MIDDLE", mid), ("TAIL", tail)):
        if c.id in seen:
            continue
        seen.add(c.id)
        parts.append(f"=== {label} (pages {c.page_start}-{c.page_end}) ===\n{_from_chunk(c)}")
    return "\n\n".join(parts)


async def scout_book(
    *,
    title: str,
    author: str | None,
    n_pages: int,
    chunks: list[Chunk],
) -> BookProposal:
    """Run the scout agent. One LLM call. Returns the structured proposal."""
    sample = _sample_text(chunks)
    prompt = (
        f"Title: {title}\n"
        f"Author: {author or '(unknown)'}\n"
        f"Pages: {n_pages}\n"
        f"Chunks (chapters/sections): {len(chunks)}\n\n"
        f"Samples from the book:\n\n{sample}"
    )
    result = await _scout_agent.run(prompt)
    return result.output
