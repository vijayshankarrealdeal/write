"""Phase 3.5 — embed chunk summaries + scene texts.

Two reasons to keep these on disk:

1. **Image regeneration.** When the user later says "make the image about
   forgiveness darker," `regenerate_image.py` semantically searches
   `embeddings/scene-*.json` to find the matching scene without re-running
   any LLM passes.

2. **Resume.** Each vector lives in its own file, written atomically. An
   interrupted embedding pass picks up by skipping items whose embedding
   file already exists.

Embedding model is the same Azure deployment the rest of the backend uses
(`AZURE_OPENAI_EMBEDDING_DEPLOYMENT`, default `text-embedding-ada-002`).
"""

from __future__ import annotations

import asyncio
import os
from typing import Iterable

from openai import AsyncAzureOpenAI

from . import persist
from .config import config
from .retry import with_retries
from .schemas import ChunkBrief, ChunkDeep


_EMBED_DEPLOYMENT = config.embedding_deployment
_EMBED_PARALLELISM = config.embed_parallelism
_EMBEDDINGS_ENABLED = os.getenv("INGEST_ENABLE_EMBEDDINGS", "true").lower() not in (
    "0", "false", "no", "off",
)


def _client() -> AsyncAzureOpenAI:
    """Embedding client — points at the dedicated embedding resource if
    AZURE_OPENAI_EMBEDDING_* env vars are set, otherwise falls back to the
    chat resource (single-account deployments)."""
    return AsyncAzureOpenAI(
        api_key=config.azure_embedding_api_key or "missing",
        azure_endpoint=config.azure_embedding_endpoint or "https://missing.invalid",
        api_version=config.azure_embedding_api_version,
    )


async def embed_one(text: str, client: AsyncAzureOpenAI) -> list[float]:
    response = await client.embeddings.create(input=text, model=_EMBED_DEPLOYMENT)
    return response.data[0].embedding


async def _probe_embedding_deployment(client: AsyncAzureOpenAI) -> str | None:
    """Single fast call to verify the deployment exists. Returns None on
    success, or a short reason string on failure. Used to short-circuit
    the per-chunk loop so a missing deployment doesn't fail 1000+ times."""
    try:
        await client.embeddings.create(input="probe", model=_EMBED_DEPLOYMENT)
        return None
    except Exception as exc:  # noqa: BLE001
        return f"{type(exc).__name__}: {exc}"


async def embed_chunks(
    slug: str,
    briefs: dict[str, ChunkBrief],
    deeps: dict[str, ChunkDeep],
) -> int:
    """Embed every chunk's summary text. Skips chunks whose embedding file
    is already on disk. Returns the count of newly-written embeddings."""
    if not _EMBEDDINGS_ENABLED:
        print("[embed/chunks] disabled via INGEST_ENABLE_EMBEDDINGS=false")
        return 0

    client = _client()
    sem = asyncio.Semaphore(_EMBED_PARALLELISM)
    written = 0
    lock = asyncio.Lock()

    todo: list[tuple[str, str]] = []
    for chunk_id, brief in briefs.items():
        if persist.has_chunk_embedding(slug, chunk_id):
            continue
        text = _chunk_embed_text(brief, deeps.get(chunk_id))
        if text:
            todo.append((chunk_id, text))

    if not todo:
        print(f"[embed/chunks] all on disk")
        return 0

    probe_err = await _probe_embedding_deployment(client)
    if probe_err:
        print(
            f"[embed/chunks] skipping — embedding deployment "
            f"'{_EMBED_DEPLOYMENT}' is unreachable on this Azure resource.\n"
            f"  Reason: {probe_err}\n"
            f"  Fix: deploy a text-embedding model and set "
            f"AZURE_OPENAI_EMBEDDING_DEPLOYMENT, or set "
            f"INGEST_ENABLE_EMBEDDINGS=false to silence this. "
            f"Pipeline continues without semantic-search regen."
        )
        return 0

    print(f"[embed/chunks] {len(todo)} to compute")

    async def _one(chunk_id: str, text: str) -> None:
        nonlocal written
        async with sem:
            try:
                vec = await with_retries(
                    lambda: embed_one(text, client),
                    label=f"embed-chunk[{chunk_id}]",
                )
            except Exception as exc:  # noqa: BLE001
                print(f"[embed/chunks] {chunk_id} failed: {exc}")
                return
            persist.write_chunk_embedding(slug, chunk_id, text, vec)
        async with lock:
            written += 1

    await asyncio.gather(*(_one(cid, text) for cid, text in todo))
    return written


async def embed_scenes(slug: str, scenes: Iterable[tuple[str, str]]) -> int:
    """Embed every (scene_id, scene_text). Skips items whose embedding
    file already exists. Returns the count newly written."""
    if not _EMBEDDINGS_ENABLED:
        print("[embed/scenes] disabled via INGEST_ENABLE_EMBEDDINGS=false")
        return 0

    client = _client()
    sem = asyncio.Semaphore(_EMBED_PARALLELISM)
    written = 0
    lock = asyncio.Lock()

    todo = [(sid, txt) for sid, txt in scenes if not persist.has_scene_embedding(slug, sid) and txt]
    if not todo:
        print(f"[embed/scenes] all on disk")
        return 0

    probe_err = await _probe_embedding_deployment(client)
    if probe_err:
        print(
            f"[embed/scenes] skipping — deployment '{_EMBED_DEPLOYMENT}' "
            f"unreachable ({probe_err}). Pipeline continues without "
            f"semantic image regeneration."
        )
        return 0

    print(f"[embed/scenes] {len(todo)} to compute")

    async def _one(scene_id: str, text: str) -> None:
        nonlocal written
        async with sem:
            try:
                vec = await with_retries(
                    lambda: embed_one(text, client),
                    label=f"embed-scene[{scene_id}]",
                )
            except Exception as exc:  # noqa: BLE001
                print(f"[embed/scenes] {scene_id} failed: {exc}")
                return
            persist.write_scene_embedding(slug, scene_id, text, vec)
        async with lock:
            written += 1

    await asyncio.gather(*(_one(sid, text) for sid, text in todo))
    return written


def _chunk_embed_text(brief: ChunkBrief, deep: ChunkDeep | None) -> str:
    """Compose the text we embed: deep summary if present, otherwise brief
    summary plus themes — both are short enough that one embedding call
    captures the chapter's semantic identity."""
    parts: list[str] = []
    if deep and deep.rich_summary:
        parts.append(deep.rich_summary)
    if brief.summary_1line:
        parts.append(brief.summary_1line)
    if brief.themes:
        parts.append("Themes: " + ", ".join(brief.themes))
    return "\n".join(parts).strip()


# -----------------------------------------------------------------------
# Cosine search — used by regenerate_image.py to map a free-text user
# instruction to a scene_id without LLM calls.
# -----------------------------------------------------------------------

def cosine(a: list[float], b: list[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = sum(x * x for x in a) ** 0.5
    nb = sum(y * y for y in b) ** 0.5
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


async def find_scene_by_query(slug: str, query: str, *, top_k: int = 5) -> list[tuple[str, float, str]]:
    """Return top-k matching (scene_id, similarity, scene_text) for `query`.

    Used by `regenerate_image.py` so the user can say "the storm scene" and
    we resolve it to a scene_id without re-running map/reduce.
    """
    import json

    book = persist.book_dir(slug)
    embed_root = book / "embeddings"
    if not any(embed_root.glob("scene-*.json")):
        return []

    client = _client()
    probe_err = await _probe_embedding_deployment(client)
    if probe_err:
        raise RuntimeError(
            f"Embedding deployment '{_EMBED_DEPLOYMENT}' is unreachable: {probe_err}. "
            f"Use scene_id directly instead of --query."
        )
    qvec = await embed_one(query, client)

    scored: list[tuple[str, float, str]] = []
    for path in embed_root.glob("scene-*.json"):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        sim = cosine(qvec, payload.get("vector") or [])
        scored.append((payload["scene_id"], sim, payload.get("text", "")))

    scored.sort(key=lambda t: t[1], reverse=True)
    return scored[:top_k]
