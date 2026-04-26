"""Unified AI router — writing assistant + recommendations."""

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.client import ensure_ai_configured
from app.ai.recommendation import recommend_for_user
from app.ai.schemas import (
    CanvasGenerateRequest,
    CanvasGenerateResponse,
    ChatRequest,
    ChatResponse,
    EmbeddingRequest,
    EmbeddingResponse,
    FeedbackRequest,
    FeedbackResponse,
    GenerateRequest,
    GenerateResponse,
    RecommendationResponse,
    RecommendedItemResponse,
    ProfileSummaryResponse,
    TextEditRequest,
    TextEditResponse,
)
from app.ai.writer_agent import (
    WritingDeps,
    content_agent,
    feedback_agent,
    get_embedding,
    writer_agent,
)
from app.auth.deps import get_current_user
from app.database import get_db
from app.models.user import User

router = APIRouter(prefix="/api/ai", tags=["ai"])


# ===== Writing assistant endpoints ==========================================

@router.post("/chat", response_model=ChatResponse)
async def chat(
    body: ChatRequest,
    user: User = Depends(get_current_user),
):
    """Free-form chat with the writing assistant."""
    ensure_ai_configured()
    deps = WritingDeps(
        user_id=str(user.id),
        writing_title=body.writing_title,
        writing_content=body.writing_content,
    )
    result = await writer_agent.run(body.message, deps=deps)
    return ChatResponse(reply=result.output)


@router.post("/feedback", response_model=FeedbackResponse)
async def feedback(
    body: FeedbackRequest,
    user: User = Depends(get_current_user),
):
    """Get structured editorial feedback on a piece of writing."""
    ensure_ai_configured()
    deps = WritingDeps(
        user_id=str(user.id),
        writing_title=body.writing_title,
        writing_content=body.writing_content,
    )
    result = await feedback_agent.run(
        f"Please review the following writing:\n\n{body.writing_content}",
        deps=deps,
    )
    fb = result.output
    return FeedbackResponse(
        summary=fb.summary,
        strengths=fb.strengths,
        suggestions=fb.suggestions,
        revised_excerpt=fb.revised_excerpt,
    )


@router.post("/generate", response_model=GenerateResponse)
async def generate(
    body: GenerateRequest,
    user: User = Depends(get_current_user),
):
    """Generate or expand writing content from a prompt."""
    ensure_ai_configured()
    deps = WritingDeps(
        user_id=str(user.id),
        writing_title=body.writing_title,
        writing_content=body.writing_content,
    )
    result = await content_agent.run(body.prompt, deps=deps)
    gen = result.output
    return GenerateResponse(title=gen.title, content=gen.content)


@router.post("/embed", response_model=EmbeddingResponse)
async def embed(
    body: EmbeddingRequest,
    _user: User = Depends(get_current_user),
):
    """Generate an embedding vector for the given text."""
    ensure_ai_configured()
    result = await get_embedding(body.text)
    return EmbeddingResponse(text=result.text, embedding=result.embedding)


# ===== Text editing endpoints =================================================

_TEXT_EDIT_PROMPTS = {
    "fix_spelling": (
        "You are a text editor. Return ONLY the corrected text with no explanations or markdown.",
        "Fix all spelling and grammar errors:\n\n{text}",
    ),
    "rewrite": (
        "You are a text editor. Return ONLY the rewritten text with no explanations or markdown.",
        "Rewrite to improve clarity, flow and style while keeping the original meaning and approximate length:\n\n{text}",
    ),
    "make_shorter": (
        "You are a text editor. Return ONLY the shortened text with no explanations or markdown.",
        "Make this more concise while keeping the key points:\n\n{text}",
    ),
    "make_longer": (
        "You are a text editor. Return ONLY the expanded text with no explanations or markdown.",
        "Expand with more detail and description while maintaining the same style and tone:\n\n{text}",
    ),
    "change_tone": (
        "You are a text editor. Return ONLY the rewritten text with no explanations or markdown.",
        "Rewrite in a {tone} tone:\n\n{text}",
    ),
    "continue_writing": (
        "You are a text editor. Return ONLY the continuation (do not repeat the original text). No explanations or markdown.",
        "Continue writing naturally, matching the same voice, style and topic. Write 2-3 more sentences:\n\n{text}",
    ),
}


@router.post("/text-edit", response_model=TextEditResponse)
async def text_edit(
    body: TextEditRequest,
    _user: User = Depends(get_current_user),
):
    """Perform a text editing action (fix spelling, rewrite, shorten, etc.)."""
    ensure_ai_configured()
    from app.ai.client import chat_client
    from app.config import settings

    prompts = _TEXT_EDIT_PROMPTS.get(body.action)
    if not prompts:
        from fastapi import HTTPException
        raise HTTPException(400, f"Unknown action: {body.action}")

    system_prompt, user_template = prompts
    user_prompt = user_template.format(text=body.text, tone=body.tone or "")

    resp = await chat_client.chat.completions.create(
        model=settings.azure_openai_chat_deployment,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        max_tokens=4096,
        temperature=0.8,
    )
    return TextEditResponse(result=resp.choices[0].message.content.strip())


@router.post("/canvas", response_model=CanvasGenerateResponse)
async def canvas_generate(
    body: CanvasGenerateRequest,
    _user: User = Depends(get_current_user),
):
    """Generate a canvas/scrapbook layout as JSON."""
    ensure_ai_configured()
    from app.ai.client import chat_client
    from app.config import settings

    context_block = ""
    if body.book_title:
        context_block += f'Book/Space title: "{body.book_title}"\n'
    if body.section_title:
        context_block += f'Current section: "{body.section_title}"\n'
    if body.other_section_titles:
        titles = ", ".join(f'"{t}"' for t in body.other_section_titles)
        context_block += f"Other sections in this book: {titles}\n"
    if body.writing_preview:
        preview = body.writing_preview[:300] + "..." if len(body.writing_preview) > 300 else body.writing_preview
        context_block += f"Written content in this section:\n{preview}\n"

    system_prompt = (
        "You are an expert scrapbook/journal page designer. Output ONLY valid JSON.\n"
        "The user gives you a THEME or TOPIC. Design a beautiful page layout with creative content INSPIRED BY the theme.\n"
        "NEVER put the user's prompt text literally on the page.\n\n"
        'OUTPUT: {"bgColor":<int ARGB>,"elements":[...]}\n'
        'For a gradient page background, add: "bgGradientStart":<int>,"bgGradientEnd":<int>,"bgGradientDirection":"top|topLeft|topRight|left"\n\n'
        "ELEMENT SCHEMAS:\n"
        'Text: {"type":"text","x":<0-1>,"y":<0-1>,"width":<0-1>,"height":<0-1>,"rotation":<rad>,"text":"...","fontFamily":"...","fontSize":<int>,"textColorValue":<int>,"bgColorValue":<int>,"isBold":<bool>,"isItalic":<bool>,"textAlign":"left|center|right","hasBorder":<bool>,"borderColorValue":<int>}\n'
        'Image: {"type":"image","x":<0-1>,"y":<0-1>,"width":<0-1>,"height":<0-1>,"rotation":0,"imageUrl":""}\n\n'
        "BOUNDS: x+width<=0.95, y+height<=0.92. No overlapping.\n"
        "Use 10-14 elements: 1 floating title, 2-3 solid cards, 1-2 gradient cards, 1-2 bordered cards, 2 image placeholders, 4-5 sticker emojis.\n"
    )

    user_prompt = f'Scrapbook page theme: "{body.prompt}"\n'
    if context_block:
        user_prompt += f"Context:\n{context_block}"

    resp = await chat_client.chat.completions.create(
        model=settings.azure_openai_chat_deployment,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        max_tokens=8192,
        temperature=0.8,
        response_format={"type": "json_object"},
    )
    return CanvasGenerateResponse(layout_json=resp.choices[0].message.content.strip())


# ===== Recommendation endpoints =============================================

@router.get("/recommendations", response_model=RecommendationResponse)
async def get_recommendations(
    limit: int = Query(20, le=50),
    use_llm_rerank: bool = Query(False),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get personalised feed recommendations based on reading patterns."""
    rec = await recommend_for_user(user, db, limit=limit, use_llm_rerank=use_llm_rerank)

    items = [
        RecommendedItemResponse(
            feed_item_id=i.feed_item_id,
            title=i.title,
            author=i.author,
            genres=i.genres,
            tags=i.tags,
            score=i.score,
            reason=i.reason,
        )
        for i in rec.items
    ]

    summary = None
    if rec.profile_summary:
        summary = ProfileSummaryResponse(
            top_genres=rec.profile_summary.top_genres,
            top_tags=rec.profile_summary.top_tags,
            top_types=rec.profile_summary.top_types,
            total_reads=rec.profile_summary.total_reads,
            total_likes=rec.profile_summary.total_likes,
        )

    return RecommendationResponse(items=items, profile_summary=summary)


@router.get("/recommendations/profile", response_model=ProfileSummaryResponse)
async def get_reading_profile(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get the user's reading preference profile (without recommendations)."""
    from app.ai.recommendation import build_user_profile

    profile = await build_user_profile(user, db)
    return ProfileSummaryResponse(
        top_genres=[g for g, _ in profile.genre_weights.most_common(5)],
        top_tags=[t for t, _ in profile.tag_weights.most_common(5)],
        top_types=[t for t, _ in profile.type_weights.most_common(5)],
        total_reads=len(profile.read_ids),
        total_likes=len(profile.liked_ids),
    )
