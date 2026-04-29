"""Shared pydantic-ai agent setup.

Two models, two agents:
  - `map_agent`   — runs on the cheap deployment, returns ChunkBrief for every chunk.
  - `reduce_agent`— runs on the expensive deployment, only on top-importance chunks.

System prompts are intentionally stable so prefix caching kicks in across
hundreds of map calls on the same book.
"""

from __future__ import annotations

from openai import AsyncAzureOpenAI
from pydantic_ai import Agent
from pydantic_ai.models.openai import OpenAIModel
from pydantic_ai.providers.openai import OpenAIProvider

from .config import config
from .schemas import ChunkBrief, ChunkDeep


def _client() -> AsyncAzureOpenAI:
    return AsyncAzureOpenAI(
        api_key=config.azure_api_key or "missing",
        azure_endpoint=config.azure_endpoint or "https://missing.invalid",
        api_version=config.azure_api_version,
    )


_shared_client = _client()

map_model = OpenAIModel(
    config.map_deployment,
    provider=OpenAIProvider(openai_client=_shared_client),
)
reduce_model = OpenAIModel(
    config.reduce_deployment,
    provider=OpenAIProvider(openai_client=_shared_client),
)
_cleaner_client = AsyncAzureOpenAI(
    api_key=config.cleaner_api_key or "missing",
    azure_endpoint=config.cleaner_endpoint or "https://missing.invalid",
    api_version=config.cleaner_api_version,
)
cleaner_model = OpenAIModel(
    config.cleaner_deployment,
    provider=OpenAIProvider(openai_client=_cleaner_client),
)


MAP_SYSTEM = (
    "You are a book-structure analyst. For the given chapter or excerpt, return:\n"
    "  - summary_1line: at most 25 words, neutral tone.\n"
    "  - importance: 0.0 (skippable boilerplate, genealogy, copyright, index) "
    "to 1.0 (pivotal narrative or doctrinal moment).\n"
    "  - themes: 1-5 short noun phrases.\n"
    "  - image_candidates: 0-3 visually striking moments. Each has scene_text "
    "(one concrete sentence a painter could illustrate) and visual_strength 0-1.\n"
    "Be honest about importance — most chapters are ~0.4. Reserve >0.8 for true peaks."
)

REDUCE_SYSTEM = (
    "You are a literary editor preparing a chapter for an annotated edition.\n"
    "Given the chapter text, return:\n"
    "  - rich_summary: 80-150 words, captures plot/argument and why it matters.\n"
    "  - highlight_spans: 2-6 spans the reader should not miss. Each is a "
    "{start, length, color_hex, why} where start/length are CHARACTER OFFSETS "
    "into the provided text. Pick spans that are quotable, pivotal, or thematic. "
    "Use #FFEB3B for key, #A5D6A7 for thematic, #F48FB1 for emotional.\n"
    "  - top_scenes: 1-3 best illustration prompts with visual_strength 0-1.\n"
    "Verify every span: text[start:start+length] must be a real substring."
)


map_agent: Agent[None, ChunkBrief] = Agent(
    model=map_model,
    output_type=ChunkBrief,
    system_prompt=MAP_SYSTEM,
)

reduce_agent: Agent[None, ChunkDeep] = Agent(
    model=reduce_model,
    output_type=ChunkDeep,
    system_prompt=REDUCE_SYSTEM,
)
