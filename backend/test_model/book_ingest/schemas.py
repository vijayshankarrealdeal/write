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
    """A candidate moment worth illustrating."""
    scene_text: str = Field(..., description="One sentence describing the scene visually.")
    visual_strength: float = Field(..., ge=0.0, le=1.0)


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
