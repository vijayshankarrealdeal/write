"""Unified AI router — writing assistant + recommendations."""

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.client import ensure_ai_configured
from app.ai.recommendation import recommend_for_user
from app.feed_visibility import public_feed_clause
from app.ai.schemas import (
    CanvasGenerateRequest,
    CanvasGenerateResponse,
    ChatRequest,
    ChatResponse,
    DeltaParagraph,
    DeltaTextEditRequest,
    DeltaTextEditResponse,
    EmbeddingRequest,
    EmbeddingResponse,
    FeedbackRequest,
    FeedbackResponse,
    GenerateRequest,
    GenerateResponse,
    RecommendationEventBatchRequest,
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
from app.models.analytics import RecommendationEvent
from app.models.feed_item import FeedItem
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

# ── Voice for transforms (replacement-style edits) ───────────────────
# Read this carefully before adding actions: every transform inherits this
# voice. Changes here ripple through the whole panel.
_WRITER_VOICE = """You're not an "AI assistant." You're a brilliant editor sitting beside the writer — invisible, taste-driven, opinionated about prose.

Voice — non-negotiable:
- Write the way a thoughtful person actually writes. Contractions. Sentence-length variety. Real beats. The occasional fragment when it lands.
- No AI tells. Banned words and phrases: "delve", "tapestry", "navigate the complexities", "leverage", "in today's fast-paced world", "moreover", "furthermore", "it's worth noting", "the journey", "embrace", "unleash", "unlock", "game-changer", "robust", "seamless", "vibrant", "elevate", "empower", "harness", "realm", "landscape", "underscore", "pivotal", "crucial", "myriad", "plethora", "testament to". If you reach for these, reach harder.
- No empty signposts: skip "In conclusion", "Overall", "It's important to note", "Let's explore", "When it comes to".
- Don't moralize, don't tie a bow on it, don't tack on conclusions the writer didn't ask for.
- Don't hedge ("perhaps", "arguably", "it could be argued") unless the original hedges.
- Concrete nouns. Active verbs. "The dog barked" beats "There was a barking sound."
- Match the writer's voice exactly. If they swear, swear. If they fragment, fragment. If they're loose and looping, follow. Polishing them into a different person is failure, not skill.
- Don't reach for em-dashes as a tic. One per paragraph at most.

Output:
- Prose only. No preamble, no "Here's the rewrite", no closing remarks.
- No markdown unless the input had markdown.
- Never explain what you changed."""


# ── Voice for feedback (advice, not replacement) ─────────────────────
_EDITOR_VOICE = """You're a sharp, kind editor reading a draft over the writer's shoulder. Your only job is to help the next version. Not to perform expertise. Not to be encouraging. To be useful.

How to talk:
- Direct. Use "I" and "you". "I lost the thread here" beats "the reader may experience confusion".
- Specific over abstract. Quote the exact line you mean (in quotes), then say what's wrong, then what would fix it.
- Honest. If something works, say so plainly — no fake enthusiasm, no compliment-sandwich.
- Brief. A sharp paragraph beats a list of generic advice. Don't pad.
- No corporate feedback theater: no "Strengths / Areas for Improvement" headers, no "Overall, this is a strong piece, but...".
- No AI tells: avoid "delve", "robust", "navigate", "leverage", "tapestry", "elevate", "underscore".

Output: prose, not bullets, unless bullets genuinely earn their place. Don't preface with "Here's my feedback". Just start."""


_TEXT_EDIT_PROMPTS = {
    # ── Sharpen: craft moves that return replacement text ────────────
    "tighten": (
        _WRITER_VOICE,
        "Tighten this. Cut filler (just, really, very, actually, basically, literally), kill weak qualifiers (a bit, sort of, kind of, somewhat), drop hedges, replace vague verbs (is/has/does/makes) with specific ones, collapse redundant phrasing. Same meaning, fewer words, sharper edges. Don't gut it — keep the writer's voice and rhythm. If a sentence already earns its length, leave it alone.\n\n{text}",
    ),
    "sharpen_opening": (
        _WRITER_VOICE,
        "Rewrite the opening so it actually pulls a reader in. The current one almost certainly warms up before getting to the point — strip that. Start in the middle of something: a concrete moment, a sharp claim, a question that costs the writer something to ask. Keep the rest of the piece untouched; only revise the first paragraph (or two if the warm-up runs longer). Return the full text with the new opening and everything that follows unchanged.\n\n{text}",
    ),
    "lift_thesis": (
        _WRITER_VOICE,
        "Find the sentence in this piece that's secretly the point — the one the writer was circling around — and rewrite the piece so that point lands earlier and harder. Move it up. Build the rest around it. Cut whatever delayed it. Don't invent a thesis the writer didn't have; surface the one already there. Return the restructured piece.\n\n{text}",
    ),
    "cut_throat_clearing": (
        _WRITER_VOICE,
        "Most writers warm up for a paragraph or two before they actually start. Find where this piece really begins and cut everything before it. If the first sentence is throat-clearing (\"In this essay I will\", \"It's interesting that\", \"For a long time I've thought\"), kill it. Sometimes whole paragraphs need to go. Return the trimmed piece, nothing more.\n\n{text}",
    ),
    "continue_writing": (
        _WRITER_VOICE,
        "Pick up exactly where this stops and write 2–3 more sentences in the writer's voice. Don't summarize what came before. Don't change topic. Don't introduce a new section unless the piece is clearly heading there. Match the rhythm, vocabulary, and stance precisely — if the writer uses fragments, you use fragments; if they're dense, you're dense. Return only the continuation.\n\n{text}",
    ),

    # ── Reframe: aim the same piece at a different reader ────────────
    "for_beginner": (
        _WRITER_VOICE,
        "Rewrite this for someone smart but new to the topic. Replace jargon with the thing it points to. Add quick context where a beginner would get lost. Don't talk down — just don't assume. Keep the writer's voice; you're translating, not dumbing down. Return the rewritten piece.\n\n{text}",
    ),
    "for_expert": (
        _WRITER_VOICE,
        "Rewrite this for a reader who already knows the basics. Cut the on-ramps and definitions experts skim past. Use precise terminology where the original handwaves. Compress where the original repeats. Assume intelligence and context. Return the rewritten piece.\n\n{text}",
    ),
    "add_example": (
        _WRITER_VOICE,
        "This piece needs a concrete example where it gets abstract. Find the most hand-wavy passage — the place that talks about the thing without showing it — and slot in one specific, vivid example, in the writer's voice. Weave it in; don't tack it on as \"For example...\" if you can avoid it. Return the full piece with the example inside.\n\n{text}",
    ),
    "steel_man": (
        _WRITER_VOICE,
        "Find this piece's main claim, then write the strongest possible counterargument — not a strawman, the real one a sharp opponent would make. Argue against the original in the original writer's voice (so they can stress-test their own thinking). 2–4 paragraphs. Return only the counterargument; do not include the original.\n\n{text}",
    ),

    # ── Feedback: read-only advice, no replacement ───────────────────
    "critique": (
        _EDITOR_VOICE,
        "Tell the writer the truth about this draft. What's actually working — name it, with the line. What's not — name it specifically, with the line that proves it. End with the one change that would do the most for the next draft. Don't list more than three things; pick the ones that matter.\n\n{text}",
    ),
    "whats_missing": (
        _EDITOR_VOICE,
        "Read this draft and find the gaps — the unsupported claim, the leap in reasoning, the example that should be here but isn't, the question a reader will have that the piece doesn't answer. Be specific: quote the spot, say what's missing, say why it matters. 2–4 gaps, max. No padding.\n\n{text}",
    ),
    "three_openings": (
        _EDITOR_VOICE,
        "Write three alternative opening paragraphs for this piece. Different angles — one in-scene, one with a sharp claim, one with a question or a surprising fact. Each in the writer's voice, each actually pulling a reader in (no warm-ups, no signposting). Number them 1, 2, 3. After each, one short line on what it does.\n\n{text}",
    ),

    # ── Legacy actions kept for backward compatibility (not in panel) ─
    "fix_spelling": (
        _WRITER_VOICE,
        "Fix spelling, grammar, and punctuation only. Do not rewrite for style, flow, or tone. Preserve the writer's voice exactly, including informal constructions and intentional fragments. Return the corrected text.\n\n{text}",
    ),

    # ── Scrivener-class name generator. The "text" field carries the
    # constraints as a JSON-ish description (gender, origin, era,
    # alliteration, surname, count). The model returns one name per
    # line, no commentary.
    "generate_names": (
        "You are a careful name-generator for fiction writers. Return one "
        "name per line, no numbering, no preamble, no explanations. Match "
        "every constraint the user gives (gender, origin, era, alliteration, "
        "surname requirements). Names should sound like real people, not "
        "stage names. Vary the rhythm — don't repeat first letters across "
        "the list unless the user asked for alliteration.",
        "Generate names with these constraints. Return only the names, one "
        "per line.\n\n{text}",
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
        max_completion_tokens=4096,
    )
    return TextEditResponse(result=resp.choices[0].message.content.strip())


@router.post("/text-edit-delta", response_model=DeltaTextEditResponse)
async def text_edit_delta(
    body: DeltaTextEditRequest,
    _user: User = Depends(get_current_user),
):
    """Delta-aware text edit. Extracts plain text from a Quill Delta, runs the
    AI action, then re-projects block/inline formatting paragraph-by-paragraph
    so headings/colors/etc. survive Accept on the client."""
    ensure_ai_configured()
    from app.ai.client import chat_client
    from app.ai.delta_utils import extract_paragraphs, reproject_edited
    from app.config import settings

    prompts = _TEXT_EDIT_PROMPTS.get(body.action)
    if not prompts:
        raise HTTPException(400, f"Unknown action: {body.action}")

    originals = extract_paragraphs(body.delta)
    plain_text = "\n\n".join(p["text"] for p in originals if p["text"]).strip()
    if not plain_text:
        raise HTTPException(400, "Delta has no text content to edit")

    system_prompt, user_template = prompts
    user_prompt = user_template.format(text=plain_text, tone=body.tone or "")

    resp = await chat_client.chat.completions.create(
        model=settings.azure_openai_chat_deployment,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        max_completion_tokens=4096,
    )
    edited_text = resp.choices[0].message.content.strip()
    edited = reproject_edited(edited_text, originals)

    return DeltaTextEditResponse(
        original_paragraphs=[DeltaParagraph(**p) for p in originals],
        edited_paragraphs=[DeltaParagraph(**p) for p in edited],
    )


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
        max_completion_tokens=8192,
        response_format={"type": "json_object"},
    )
    return CanvasGenerateResponse(layout_json=resp.choices[0].message.content.strip())


# ===== Recommendation endpoints =============================================

@router.get("/recommendations", response_model=RecommendationResponse)
async def get_recommendations(
    limit: int = Query(20, le=50),
    use_llm_rerank: bool | None = Query(
        None,
        description=(
            "True forces LLM re-rank, False disables it, omit for auto: "
            "rerank when the profile is rich enough."
        ),
    ),
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
            author_id=i.author_id,
            description=i.description,
            image_url=i.image_url,
            image_meta=i.image_meta,
            genres=i.genres,
            writing_types=i.writing_types,
            tags=i.tags,
            likes_count=i.likes_count,
            comments_count=i.comments_count,
            # `sections` is intentionally None — chapter bodies live in
            # the `sections` table; the reader fetches them via
            # `/api/feed/{id}/sections/{section_id}` on tap-through.
            sections=None,
            is_draft=i.is_draft,
            created_at=i.created_at,
            updated_at=i.updated_at,
            score=i.score,
            reason=i.reason,
            source=i.source,
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
            is_cold_start=rec.profile_summary.is_cold_start,
        )

    return RecommendationResponse(
        items=items,
        profile_summary=summary,
        session_id=rec.session_id,
    )


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
        is_cold_start=profile.is_cold_start,
    )


@router.get(
    "/recommendations/similar/{feed_item_id}",
    response_model=list[RecommendedItemResponse],
)
async def get_similar_items(
    feed_item_id: UUID,
    limit: int = Query(10, le=25),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Return the N nearest pgvector neighbours of the given feed item.

    Powers the "More like this" carousel on the read page. Falls back
    to a 200 with an empty list when the source item has no embedding
    yet (rather than 404'ing — the carousel just hides itself).
    """
    # Seed lookup must respect the visibility gate — if the viewer can't
    # read the source item, "similar to it" is meaningless and would also
    # leak that the item exists.
    seed_q = await db.execute(
        select(FeedItem.id, FeedItem.embedding, FeedItem.is_draft)
        .where(FeedItem.id == feed_item_id)
        .where(
            or_(
                FeedItem.author_id == user.id,
                public_feed_clause(user.id),
            )
        )
    )
    seed = seed_q.first()
    if seed is None:
        raise HTTPException(404, "Feed item not found")
    if seed.is_draft or seed.embedding is None:
        return []

    distance = FeedItem.embedding.cosine_distance(seed.embedding)
    try:
        rows = (
            await db.execute(
                select(FeedItem, distance.label("dist"))
                .where(public_feed_clause(user.id))
                .where(FeedItem.id != feed_item_id)
                .where(FeedItem.embedding.is_not(None))
                .order_by(distance)
                .limit(limit)
            )
        ).all()
    except Exception:
        # pgvector unavailable — degrade to empty rather than 500'ing.
        return []

    out: list[RecommendedItemResponse] = []
    for item, dist in rows:
        similarity = max(0.0, 1.0 - float(dist))
        out.append(
            RecommendedItemResponse(
                feed_item_id=str(item.id),
                title=item.title,
                author=item.author,
                author_id=str(item.author_id) if item.author_id else None,
                description=item.description,
                image_url=item.image_url,
                image_meta=item.image_meta,
                genres=item.genres or [],
                writing_types=item.writing_types or [],
                tags=item.tags or [],
                likes_count=item.likes_count or 0,
                comments_count=item.comments_count or 0,
                # Bodies live in the `sections` table — see
                # /api/feed/{id}/sections/{section_id} for lazy load.
                sections=None,
                is_draft=item.is_draft,
                created_at=item.created_at,
                updated_at=item.updated_at,
                score=similarity,
                reason=None,
                source="semantic",
            )
        )
    return out


@router.post("/recommendations/events", status_code=204)
async def log_recommendation_events(
    body: RecommendationEventBatchRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Bulk-log impressions / clicks against recommended items.

    Returns 204 on success. Invalid feed_item_ids in the batch are
    skipped silently — analytics shouldn't fail the user's render.
    """
    if not body.events:
        return

    rows: list[RecommendationEvent] = []
    for ev in body.events:
        try:
            fid = UUID(ev.feed_item_id)
        except (ValueError, TypeError):
            continue
        if ev.event_type not in {"impression", "click"}:
            raise HTTPException(400, f"unknown event_type: {ev.event_type}")
        rows.append(
            RecommendationEvent(
                user_id=user.id,
                feed_item_id=fid,
                event_type=ev.event_type,
                position=ev.position,
                score=ev.score,
                source=ev.source,
                session_id=ev.session_id,
            )
        )

    if rows:
        db.add_all(rows)
        await db.commit()
