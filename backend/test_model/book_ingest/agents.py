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
    "You are a book-structure analyst with a cinematographer's eye. For the "
    "given chapter or excerpt, return:\n"
    "  - summary_1line: at most 25 words, neutral tone.\n"
    "  - importance: 0.0 (skippable boilerplate, genealogy, copyright, index) "
    "to 1.0 (pivotal narrative or doctrinal moment).\n"
    "  - themes: 1-5 short noun phrases.\n"
    "  - image_candidates: 1-3 visually striking moments. For each, fill EVERY "
    "field — they shape the final illustration:\n"
    "      scene_text: one concrete sentence a painter could illustrate "
    "(focus on ONE moment, not a montage).\n"
    "      visual_strength: 0-1, honest. >0.8 only for genuinely iconic moments.\n"
    "      mood: 1-3 words for the emotional register ('dread', 'tender awe', "
    "'comic chaos', 'reverent stillness').\n"
    "      composition: one of close-up / medium / wide / establishing / "
    "overhead / low-angle. Pick the framing that serves the moment.\n"
    "      time_of_day: when it happens, in concrete light terms "
    "('dawn', 'golden hour', 'storm-grey afternoon', 'candle-lit interior').\n"
    "      setting: where it happens, one short visual phrase.\n"
    "      characters_present: list of named characters visible — use the "
    "exact spelling the book uses. Empty list if the scene is a landscape "
    "or has no named figures.\n"
    "      palette_hint: only when a scene needs a palette distinct from "
    "the book's overall voice (e.g. battle scenes, dream sequences). "
    "Otherwise null.\n"
    "Vary composition across the candidates you return — don't propose three "
    "close-ups in a row. Mix in at least one wide or establishing shot when "
    "the chapter supports it.\n"
    "Be honest about importance — most chapters are ~0.4. Reserve >0.8 for true peaks."
)

REDUCE_SYSTEM = (
    "You are a literary editor and art director preparing a chapter for an "
    "illustrated edition.\n"
    "Given the chapter text, return:\n"
    "  - rich_summary: 80-150 words, captures plot/argument and why it matters.\n"
    "  - highlight_spans: 2-6 spans the reader should not miss. Each is a "
    "{start, length, color_hex, why} where start/length are CHARACTER OFFSETS "
    "into the provided text. Pick spans that are quotable, pivotal, or thematic. "
    "Use #FFEB3B for key, #A5D6A7 for thematic, #F48FB1 for emotional.\n"
    "  - top_scenes: 1-3 best illustration prompts. For each scene fill EVERY "
    "field so the image-gen phase has cinematic guidance:\n"
    "      scene_text, visual_strength, mood, composition (close-up / medium / "
    "wide / establishing / overhead / low-angle), time_of_day, setting, "
    "characters_present (named figures, exact book spelling), and "
    "palette_hint (only when the scene needs a palette distinct from the "
    "book's overall voice).\n"
    "Aim for variety: one intimate moment, one grand moment, one atmospheric "
    "moment — don't pick three of the same shape.\n"
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
