"""Pydantic types passed between phases.

Kept narrow on purpose — the agents return the smallest structure that the
next phase can act on. Anything broader makes the LLM hallucinate fields.
"""

from __future__ import annotations

from pydantic import BaseModel, Field


class Page(BaseModel):
    no: int
    text: str
    char_count: int = 0


class Chunk(BaseModel):
    id: str
    chapter_title: str | None = None
    page_start: int
    page_end: int
    text: str

    @property
    def char_count(self) -> int:
        return len(self.text)


class SceneBrief(BaseModel):
    """A candidate moment worth illustrating.

    `scene_text` is the only required field; the rest are optional
    cinematic hints that the image-gen phase folds into the prompt.
    Older briefs cached on disk pre-date these fields, so they all
    default — deserialization stays backward-compatible.
    """
    scene_text: str = Field(..., description="One sentence describing the scene visually.")
    visual_strength: float = Field(..., ge=0.0, le=1.0)
    mood: str | None = Field(
        None,
        description=(
            "Emotional register in 1-3 words. Examples: 'tender, awestruck', "
            "'dread', 'comic chaos', 'reverent', 'foreboding'. Drives lighting "
            "and palette choices in the image."
        ),
    )
    composition: str | None = Field(
        None,
        description=(
            "Cinematic framing hint. Pick one: 'close-up' (face/object), "
            "'medium' (one or two figures waist-up), 'wide' (figures in setting), "
            "'establishing' (landscape/architecture, figures small or absent), "
            "'overhead' (top-down), 'low-angle' (looking up). Drives aspect "
            "ratio and depth-of-field."
        ),
    )
    time_of_day: str | None = Field(
        None,
        description=(
            "When this moment happens, in 1-3 words. Examples: 'dawn', "
            "'noon', 'golden hour', 'dusk', 'moonlit night', 'storm-grey "
            "afternoon', 'candle-lit interior'. Drives the light direction "
            "and warmth."
        ),
    )
    setting: str | None = Field(
        None,
        description=(
            "Where the moment takes place, concrete and visual. Examples: "
            "'a Victorian drawing room with heavy curtains', 'a windswept "
            "alpine pass', 'the deck of a wooden ship at night', 'the marble "
            "courtyard of a Mughal palace'."
        ),
    )
    characters_present: list[str] = Field(
        default_factory=list,
        description=(
            "Named characters visible in this scene. Use the canonical name "
            "as it appears in the book ('Alice', 'Victor Frankenstein', "
            "'Bhīma'). Empty when the scene has no named figures (landscape, "
            "still life). Drives character continuity across illustrations."
        ),
    )
    palette_hint: str | None = Field(
        None,
        description=(
            "Optional palette steer when this scene needs a specific color "
            "language different from the book's base style — e.g. 'crimson "
            "and gunmetal grey' for a battle, 'pale jade and mist' for a "
            "ghost scene. null when the book-wide style is enough."
        ),
    )


class ChunkBrief(BaseModel):
    """Output of the cheap map pass — exists for every chunk."""
    summary_1line: str
    importance: float = Field(..., ge=0.0, le=1.0)
    themes: list[str] = Field(default_factory=list)
    image_candidates: list[SceneBrief] = Field(default_factory=list)


class HighlightSpan(BaseModel):
    """Character offsets into the chunk's text."""
    start: int
    length: int
    color_hex: str = "#FFEB3B"
    why: str


class ChunkDeep(BaseModel):
    """Output of the gated reduce pass — only for high-importance chunks."""
    rich_summary: str
    highlight_spans: list[HighlightSpan] = Field(default_factory=list)
    top_scenes: list[SceneBrief] = Field(default_factory=list)


class GeneratedScene(BaseModel):
    scene_id: str
    chunk_id: str
    prompt: str
    image_path: str
