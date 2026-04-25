"""Shared Azure OpenAI clients and Pydantic-AI model used by all AI modules."""

from openai import AsyncAzureOpenAI
from pydantic_ai.models.openai import OpenAIModel
from pydantic_ai.providers.openai import OpenAIProvider

from app.config import settings

# ---------------------------------------------------------------------------
# Azure OpenAI async clients (one for chat, one for embeddings)
# ---------------------------------------------------------------------------

chat_client = AsyncAzureOpenAI(
    api_key=settings.azure_openai_api_key,
    azure_endpoint=settings.azure_openai_endpoint,
    api_version=settings.azure_openai_api_version,
)

embedding_client = AsyncAzureOpenAI(
    api_key=settings.azure_openai_api_key,
    azure_endpoint=settings.azure_openai_endpoint,
    api_version=settings.azure_openai_api_version,
)

# ---------------------------------------------------------------------------
# Pydantic-AI model wrapper (points at the chat deployment)
# ---------------------------------------------------------------------------

model = OpenAIModel(
    settings.azure_openai_chat_deployment,
    provider=OpenAIProvider(openai_client=chat_client),
)
