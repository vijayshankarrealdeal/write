"""Shared Azure OpenAI clients and Pydantic-AI model used by all AI modules."""

from fastapi import HTTPException
from openai import AsyncAzureOpenAI
from pydantic_ai.models.openai import OpenAIModel
from pydantic_ai.providers.openai import OpenAIProvider

from app.config import settings

# ---------------------------------------------------------------------------
# Azure OpenAI async clients (one for chat, one for embeddings)
# ---------------------------------------------------------------------------

chat_client = AsyncAzureOpenAI(
    api_key=settings.azure_openai_api_key or "missing",
    azure_endpoint=settings.azure_openai_endpoint or "https://missing.invalid",
    api_version=settings.azure_openai_api_version,
)

embedding_client = AsyncAzureOpenAI(
    api_key=settings.azure_openai_api_key or "missing",
    azure_endpoint=settings.azure_openai_endpoint or "https://missing.invalid",
    api_version=settings.azure_openai_api_version,
)


def ai_configured() -> bool:
    return bool(settings.azure_openai_api_key and settings.azure_openai_endpoint)


def ensure_ai_configured() -> None:
    if not ai_configured():
        raise HTTPException(
            status_code=503,
            detail=(
                "AI features are not configured. Set AZURE_OPENAI_API_KEY and "
                "AZURE_OPENAI_ENDPOINT in the backend environment."
            ),
        )

# ---------------------------------------------------------------------------
# Pydantic-AI model wrapper (points at the chat deployment)
# ---------------------------------------------------------------------------

model = OpenAIModel(
    settings.azure_openai_chat_deployment,
    provider=OpenAIProvider(openai_client=chat_client),
)
