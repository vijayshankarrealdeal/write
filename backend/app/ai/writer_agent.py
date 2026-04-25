"""Writing-assistant agents (chat, feedback, content generation, embeddings)."""

from __future__ import annotations

from dataclasses import dataclass

from pydantic import BaseModel
from pydantic_ai import Agent, RunContext

from app.ai.client import embedding_client, model
from app.config import settings


# ---------------------------------------------------------------------------
# Dependency injected into every agent tool call
# ---------------------------------------------------------------------------

@dataclass
class WritingDeps:
    user_id: str | None = None
    writing_title: str | None = None
    writing_content: str | None = None


# ---------------------------------------------------------------------------
# Structured result types
# ---------------------------------------------------------------------------

class WritingFeedback(BaseModel):
    summary: str
    strengths: list[str]
    suggestions: list[str]
    revised_excerpt: str | None = None


class GeneratedContent(BaseModel):
    title: str | None = None
    content: str


class EmbeddingResult(BaseModel):
    text: str
    embedding: list[float]


# ---------------------------------------------------------------------------
# Agents
# ---------------------------------------------------------------------------

writer_agent = Agent(
    model=model,
    deps_type=WritingDeps,
    result_type=str,
    system_prompt=(
        "You are a professional writing assistant for InkSpaceX, a creative "
        "writing platform. You help authors brainstorm, draft, edit, and "
        "improve their work. Be encouraging but honest. When giving feedback, "
        "be specific and actionable. Adapt your tone to match the genre the "
        "author is working in."
    ),
)

feedback_agent = Agent(
    model=model,
    deps_type=WritingDeps,
    result_type=WritingFeedback,
    system_prompt=(
        "You are a literary editor. Analyse the provided writing and return "
        "structured feedback: a brief summary, a list of strengths, a list of "
        "concrete suggestions for improvement, and optionally a short revised "
        "excerpt demonstrating one of your suggestions."
    ),
)

content_agent = Agent(
    model=model,
    deps_type=WritingDeps,
    result_type=GeneratedContent,
    system_prompt=(
        "You are a creative writing assistant. Generate content based on the "
        "user's prompt. If they provide a title or outline, expand on it. "
        "Return a title (if appropriate) and the generated content."
    ),
)


# ---------------------------------------------------------------------------
# Agent tools
# ---------------------------------------------------------------------------

@writer_agent.tool
async def get_writing_context(ctx: RunContext[WritingDeps]) -> str:
    """Return the current writing context (title + content) if available."""
    deps = ctx.deps
    parts: list[str] = []
    if deps.writing_title:
        parts.append(f"Title: {deps.writing_title}")
    if deps.writing_content:
        parts.append(f"Content:\n{deps.writing_content}")
    return "\n".join(parts) if parts else "No writing context provided."


@writer_agent.tool
async def word_count(ctx: RunContext[WritingDeps]) -> str:
    """Count words in the current writing content."""
    text = ctx.deps.writing_content or ""
    words = len(text.split())
    return f"The current content has {words} words."


# ---------------------------------------------------------------------------
# Embedding helper
# ---------------------------------------------------------------------------

async def get_embedding(text: str) -> EmbeddingResult:
    """Generate an embedding vector for the given text via Azure OpenAI."""
    response = await embedding_client.embeddings.create(
        input=text,
        model=settings.azure_openai_embedding_deployment,
    )
    vector = response.data[0].embedding
    return EmbeddingResult(text=text, embedding=vector)
