"""Request / response schemas for all AI endpoints."""

from pydantic import BaseModel


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
    action: str  # fix_spelling, rewrite, make_shorter, make_longer, change_tone, continue_writing
    text: str
    tone: str | None = None  # only for change_tone


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
    feed_item_id: str
    title: str | None
    author: str | None
    genres: list[str]
    tags: list[str]
    score: float
    reason: str | None = None


class ProfileSummaryResponse(BaseModel):
    top_genres: list[str]
    top_tags: list[str]
    top_types: list[str]
    total_reads: int
    total_likes: int


class RecommendationResponse(BaseModel):
    items: list[RecommendedItemResponse]
    profile_summary: ProfileSummaryResponse | None = None
