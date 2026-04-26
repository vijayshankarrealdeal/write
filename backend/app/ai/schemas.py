"""Request / response schemas for all AI endpoints."""

from datetime import datetime

from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Writing assistant
# ---------------------------------------------------------------------------

class ChatRequest(BaseModel):
    message: str
    writing_title: str | None = None
    writing_content: str | None = None


class ChatResponse(BaseModel):
    reply: str


class FeedbackRequest(BaseModel):
    writing_title: str | None = None
    writing_content: str


class FeedbackResponse(BaseModel):
    summary: str
    strengths: list[str]
    suggestions: list[str]
    revised_excerpt: str | None = None


class GenerateRequest(BaseModel):
    prompt: str
    writing_title: str | None = None
    writing_content: str | None = None


class GenerateResponse(BaseModel):
    title: str | None = None
    content: str


class EmbeddingRequest(BaseModel):
    text: str


class EmbeddingResponse(BaseModel):
    text: str
    embedding: list[float]


# ---------------------------------------------------------------------------
# Text editing (fix spelling, rewrite, tone, etc.)
# ---------------------------------------------------------------------------

class TextEditRequest(BaseModel):
    # Sharpen:  tighten, sharpen_opening, lift_thesis, cut_throat_clearing, continue_writing
    # Reframe:  for_beginner, for_expert, add_example, steel_man
    # Feedback: critique, whats_missing, three_openings
    # Legacy:   fix_spelling
    action: str
    text: str
    tone: str | None = None  # reserved; no current action consumes it


class TextEditResponse(BaseModel):
    result: str


class CanvasGenerateRequest(BaseModel):
    prompt: str
    book_title: str | None = None
    section_title: str | None = None
    other_section_titles: list[str] = []
    writing_preview: str | None = None


class CanvasGenerateResponse(BaseModel):
    layout_json: str


# ---------------------------------------------------------------------------
# Recommendations
# ---------------------------------------------------------------------------

class RecommendationRequest(BaseModel):
    limit: int = 20
    use_llm_rerank: bool = False


class RecommendedItemResponse(BaseModel):
    """A recommended feed item.

    Carries every field the Flutter card needs so the client can render
    the shelf without an N+1 fetch-by-id round-trip per recommendation.
    """

    feed_item_id: str
    title: str | None
    author: str | None
    author_id: str | None = None
    description: str | None = None
    image_url: str | None = None
    image_meta: dict | None = None
    genres: list[str] = []
    writing_types: list[str] = []
    tags: list[str] = []
    likes_count: int = 0
    comments_count: int = 0
    sections: list[dict] | None = None
    is_draft: bool = False
    created_at: datetime | None = None
    updated_at: datetime | None = None
    score: float
    reason: str | None = None
    source: str = "engine"  # "engine" | "cold_start" | "llm_rerank"


class ProfileSummaryResponse(BaseModel):
    top_genres: list[str]
    top_tags: list[str]
    top_types: list[str]
    total_reads: int
    total_likes: int
    is_cold_start: bool = False


class RecommendationResponse(BaseModel):
    items: list[RecommendedItemResponse]
    profile_summary: ProfileSummaryResponse | None = None
    # Opaque grouping id — the client echoes this back on impression /
    # click events so we can correlate a render with its outcomes.
    session_id: str


class RecommendationEventRequest(BaseModel):
    """Client-side event log for a recommendation card.

    The client posts one batch per visible-card flush + one per click.
    Position is 1-based to match the user-facing slot.
    """

    feed_item_id: str
    event_type: str = Field(pattern=r"^(impression|click)$")
    position: int | None = None
    score: float | None = None
    source: str | None = None
    session_id: str | None = None


class RecommendationEventBatchRequest(BaseModel):
    events: list[RecommendationEventRequest]
