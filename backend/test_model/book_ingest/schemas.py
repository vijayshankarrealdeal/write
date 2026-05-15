"""Pydantic types — the contract Claude writes to disk, the server reads.

Two families:

  • **Pipeline-input** types (ScenePrompt, CharacterPrompt, CoverPrompt,
    Poster) — written by finalize.py, consumed by the image-gen phase
    in studio/server.py. Dispose-internal.

  • **Sync-output** types (Page, Chunk, SceneBrief, ChunkBrief,
    ChunkDeep, GeneratedScene, HighlightSpan) — the format the
    production VM's sync_to_db.py expects on disk. Mirrors
    `/Users/vijayshankar/Desktop/write/backend/test_model/book_ingest/schemas.py`
    so an imported or freshly-ingested book can be published without
    translation.
"""
from __future__ import annotations

from pydantic import BaseModel, Field


# ─── Sync-output (mirrors production VM schemas) ──────────────────────


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
    scene_text: str = Field(...)
    visual_strength: float = Field(..., ge=0.0, le=1.0)
    mood: str | None = None
    composition: str | None = None
    time_of_day: str | None = None
    setting: str | None = None
    characters_present: list[str] = Field(default_factory=list)
    palette_hint: str | None = None


class ChunkBrief(BaseModel):
    summary_1line: str
    importance: float = Field(..., ge=0.0, le=1.0)
    themes: list[str] = Field(default_factory=list)
    image_candidates: list[SceneBrief] = Field(default_factory=list)


class SyncHighlightSpan(BaseModel):
    """Highlight format the production sync_to_db.py expects. Note `why`
    is required and there's no `kind` — distinct from dispose's pipeline
    HighlightSpan below."""
    start: int
    length: int
    color_hex: str = "#FFEB3B"
    why: str


class ChunkDeep(BaseModel):
    rich_summary: str
    highlight_spans: list[SyncHighlightSpan] = Field(default_factory=list)
    top_scenes: list[SceneBrief] = Field(default_factory=list)


class GeneratedScene(BaseModel):
    scene_id: str
    chunk_id: str
    prompt: str
    image_path: str


# ─── Pipeline-input (dispose-internal) ────────────────────────────────


class HighlightSpan(BaseModel):
    start: int
    length: int
    color_hex: str
    kind: str  # "key" | "thematic" | "emotional"
    why: str = ""


class ScenePrompt(BaseModel):
    scene_id: str
    chunk_id: str
    scene_text: str
    prompt: str
    negative: str = "no text, no logos, no signature, no watermark"
    size: str = "1024x1536"
    characters_present: list[str] = Field(default_factory=list)
    character_sheet_refs: list[str] = Field(default_factory=list)
    status: str = "pending"  # pending | ready | failed
    image_path: str | None = None
    generated_at: str | None = None
    attempts: list[dict] = Field(default_factory=list)


class CharacterPrompt(BaseModel):
    name: str
    appearance: str
    bio: str
    prompt: str
    negative: str = "no text, no logos, no signature, no watermark"
    size: str = "1024x1024"
    status: str = "pending"
    image_path: str | None = None
    generated_at: str | None = None
    attempts: list[dict] = Field(default_factory=list)


class CoverPrompt(BaseModel):
    scene: str
    prompt: str
    character_sheet_refs: list[str] = Field(default_factory=list)
    negative: str = "no text, no logos, no signature, no watermark"
    size: str = "1024x1536"
    status: str = "pending"
    image_path: str | None = None
    generated_at: str | None = None
    attempts: list[dict] = Field(default_factory=list)
    title_overlay: dict | None = None  # {title, subtitle, author}


class Poster(BaseModel):
    back_cover_copy: str
    genres: list[str] = Field(default_factory=list)
    writing_types: list[str] = Field(default_factory=lambda: ["book"])
    tags: list[str] = Field(default_factory=list)
