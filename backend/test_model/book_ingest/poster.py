"""Phase 6.5 — generate the book "poster".

The Flutter post_detail_page (and the feed card) renders a book using
these FeedItem fields, in this priority order:

    title          (header, big)
    author         (header, italic)
    imageUrl       (backdrop + floating cover)
    description    (long blurb shown below the stats row)
    genres[]       (chip pills)
    writingTypes[] (chip pills)
    tags[]         (chip pills)
    sections[]     (the chapters)

Without this phase, the publisher fills only title/author/imageUrl from
the scout — `description`, `genres`, `tags`, `writingTypes` are empty
and the book detail page is ugly. The poster agent reads what the
pipeline already produced (scout proposal + a sample of deep summaries)
and emits the missing fields in one LLM call.

It also generates ONE distinct "cover" illustration — different from
individual chapter scenes — that becomes the FeedItem's imageUrl /
Writing.cover_image_path.
"""

from __future__ import annotations

import asyncio
from pathlib import Path

from pydantic import BaseModel, Field, field_validator, model_validator
from pydantic_ai import Agent

from . import persist
from .agents import reduce_model
from .app_taxonomy import (
    WRITING_TYPE_FORMATS,
    WRITING_TYPES,
    coerce_writing_type,
    coerce_writing_type_format,
)
from .image_gen import generate_image
from .retry import with_retries
from .schemas import ChunkBrief, ChunkDeep


class BookPoster(BaseModel):
    """The flat metadata that drives the book detail page in the app.

    `writing_types` MUST align with the Flutter app's WritingType enum so
    user preference filters (onboarding + Feed Preferences page) actually
    match published content:
      - writing_types[0] is the WritingType (one of creative,
        digitalContent, personal, journalistic, marketing).
      - writing_types[1] (optional) is a "format" / subtype label
        belonging to that writing type — e.g. "Short Story" for
        creative, "Blog Post" for digitalContent.
    The validator below snaps any LLM-emitted synonyms back onto this
    taxonomy so a wonky output doesn't silently break filtering.
    """
    description: str = Field(
        ...,
        description=(
            "200-400 word back-cover-style summary of the book's content. "
            "Should hint at major arcs, key characters, and emotional tone "
            "without spoiling specific revelations. Reads as marketing copy, "
            "not a Wikipedia summary."
        ),
    )
    genres: list[str] = Field(
        default_factory=list,
        max_length=4,
        description=(
            "Top-level genre buckets, lowercase. Free-form (the app surfaces "
            "whatever values appear in published content as filter chips). "
            "E.g. ['mythology', 'religion', 'hinduism']."
        ),
    )
    writing_types: list[str] = Field(
        default_factory=list,
        min_length=1,
        max_length=2,
        description=(
            "EXACTLY two entries from the app's WritingType taxonomy:\n"
            "  [0] = writing type (one of: creative, digitalContent, "
            "personal, journalistic, marketing)\n"
            "  [1] = format/subtype belonging to that writing type "
            "(see allowed_formats below)\n\n"
            "Allowed formats per writing type:\n"
            "  - creative:        Short Story, Poetry, Script, Flash Fiction\n"
            "  - digitalContent:  Blog Post, Newsletter, Social Media Post, "
            "Caption, Thread, Reels Script\n"
            "  - personal:        Storytime, Rant, Open Letter, Life Update, "
            "Affirmation, Deep Talk, Relationship Tea, Mental Health Log\n"
            "  - journalistic:    News Article, Editorial, Opinion Piece, Interview\n"
            "  - marketing:       Ad Copy, Product Description, Email Campaign, Slogan\n\n"
            "Use displayName casing for [1] (e.g. 'Short Story', not 'short-story'). "
            "Most ingested books are 'creative' / 'Short Story' (long-form fiction "
            "or mythic retellings) — pick journalistic/personal only when the "
            "source genuinely fits."
        ),
    )
    tags: list[str] = Field(
        default_factory=list,
        max_length=10,
        description=(
            "Granular discoverability tags, lowercase, hyphenated. Free-form. "
            "E.g. ['mahabharata', 'sanskrit', 'ancient-india', 'kurukshetra', "
            "'pandavas', 'kauravas', 'dharma', 'bhagavad-gita']."
        ),
    )
    cover_scene: str = Field(
        ...,
        description=(
            "One-sentence visual brief for the book's hero/cover illustration, "
            "different from any individual chapter scene. Should evoke the "
            "whole work, not a specific moment."
        ),
    )

    @field_validator("genres", "tags", mode="before")
    @classmethod
    def _normalize_free_form(cls, v: list[str] | None) -> list[str]:
        """Lowercase + hyphenate so casing differences don't fragment the
        feed_facets chip list ('Mythology' and 'mythology' must merge)."""
        if not v:
            return []
        out: list[str] = []
        seen: set[str] = set()
        for item in v:
            if not isinstance(item, str):
                continue
            cleaned = "-".join(item.strip().lower().split())
            if cleaned and cleaned not in seen:
                seen.add(cleaned)
                out.append(cleaned)
        return out

    @model_validator(mode="after")
    def _snap_writing_types(self) -> "BookPoster":
        """Coerce writing_types onto the app's WritingType+format taxonomy.

        The LLM occasionally emits synonyms ('epic', 'sacred-text',
        'translation') — those would render as filter chips users can
        never select. Map them back to the canonical pair so filtering
        works end-to-end.
        """
        wt_raw = self.writing_types[0] if self.writing_types else None
        fmt_raw = self.writing_types[1] if len(self.writing_types) > 1 else None

        wt = coerce_writing_type(wt_raw)
        fmt = coerce_writing_type_format(wt, fmt_raw)
        self.writing_types = [wt, fmt]
        return self


_POSTER_SYSTEM = (
    "You write book-jacket copy. Given a book's title, scout-detected "
    "genre + cultural context, and a sampling of chapter summaries, you "
    "produce the metadata that drives the book's detail page in a "
    "reading app: a back-cover description, genre/type/tag taxonomy, "
    "and a brief for the cover illustration.\n\n"
    "Be specific and confident. The description should make a reader "
    "want to open the book. The cover_scene should evoke the whole work "
    "(not one moment) and should be distinct from chapter illustrations.\n\n"
    "writing_types is a CLOSED taxonomy that must match the reader app's "
    "WritingType enum exactly — do NOT invent values like 'sacred-text' or "
    "'epic'. Pick:\n"
    "  writing_types[0] ∈ {" + ", ".join(WRITING_TYPES) + "}\n"
    "  writing_types[1] ∈ formats for that type (see schema description).\n"
    "For most ingested long-form books, the right answer is "
    "['creative', 'Short Story']."
)


_poster_agent: Agent[None, BookPoster] = Agent(
    model=reduce_model,
    output_type=BookPoster,
    system_prompt=_POSTER_SYSTEM,
)


def _sample_deeps(deeps: dict[str, ChunkDeep], *, limit: int = 12) -> str:
    """Pick the highest-quality summaries to feed the poster agent. Used
    by sort, but caller passes the dict — we just take the longest 12
    summaries as a proxy for richness."""
    items = sorted(
        ((cid, d.rich_summary or "") for cid, d in deeps.items()),
        key=lambda kv: len(kv[1]),
        reverse=True,
    )
    return "\n\n".join(s for _, s in items[:limit] if s)


async def generate_poster(
    *,
    title: str,
    author: str | None,
    scout_data: dict | None,
    briefs: dict[str, ChunkBrief],
    deeps: dict[str, ChunkDeep],
) -> BookPoster:
    """One LLM call. Returns the structured poster metadata."""
    summaries = _sample_deeps(deeps)
    if not summaries.strip():
        # Fallback to brief 1-liners if reduce hadn't run yet.
        summaries = "\n".join(
            f"- {b.summary_1line}" for b in list(briefs.values())[:30]
        )

    scout_block = ""
    if scout_data:
        scout_block = (
            f"Scout's read: genre={scout_data.get('detected_genre')!r}, "
            f"context={scout_data.get('cultural_context')!r}, "
            f"style={scout_data.get('suggested_style')!r}.\n\n"
        )

    prompt = (
        f"Title: {title}\n"
        f"Author: {author or '(unknown)'}\n\n"
        f"{scout_block}"
        f"Sample of chapter summaries:\n{summaries}"
    )
    result = await with_retries(
        lambda: _poster_agent.run(prompt),
        label="poster",
    )
    return result.output


async def generate_cover_image(
    slug: str,
    *,
    cover_scene: str,
    style: str | None,
    reader_preference: str | None,
    base_palette: str | None = None,
    character_refs: list[str] | None = None,
) -> Path | None:
    """Generate one extra illustration that becomes the book's cover.
    Saved as `images/cover.png` so it sits alongside the scene PNGs but
    has a stable, predictable filename.

    The cover is the single most-viewed image of a book — the feed card
    has to stop a scrolling reader. So we layer in:
      - `book cover composition` framing (centered hero, deliberate
        margins for the title overlay the app may add later)
      - portrait aspect ratio (1024x1536) — matches how cards render
      - high quality
      - base_palette + character refs (when the cover scene names them),
        for consistency with the interior illustrations
    """
    out_path = persist.book_dir(slug) / "images" / "cover.png"
    cover_brief = (
        f"book cover composition, hero focal subject, magazine-poster "
        f"impact, dramatic but balanced negative space for a title "
        f"overlay. Subject: {cover_scene.strip().rstrip('.')}"
    )
    try:
        await with_retries(
            lambda: generate_image(
                cover_brief,
                str(out_path),
                style=style,
                reader_preference=reader_preference,
                base_palette=base_palette,
                character_refs=character_refs,
                quality="high",
                size="1024x1536",  # portrait — matches feed-card aspect
            ),
            label="cover",
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[poster] cover image failed: {exc}")
        return None
    # Mirror scene-meta layout so the studio's image listings can show it.
    persist._atomic_write_text(  # type: ignore[attr-defined]
        out_path.with_suffix(".json"),
        _cover_meta_json(slug, cover_scene, str(out_path)),
    )
    return out_path


def _cover_meta_json(slug: str, scene: str, image_path: str) -> str:
    import json
    return json.dumps({
        "scene_id": "cover",
        "chunk_id": None,
        "chapter_title": "(book cover)",
        "score": 1.0,
        "prompt": scene,
        "scene_text": scene,
        "image_path": image_path,
        "is_cover": True,
    }, indent=2)
