"""Phase 2 — cheap map pass over every chunk.

Each chunk's brief is persisted to `briefs/<chunk_id>.json` *as it
completes*, not at the end of the phase. A power cut at chunk 347 of 600
keeps the 346 already on disk. Resume only re-runs chunks whose brief
file is missing or unparseable.
"""

from __future__ import annotations

import asyncio

from . import persist
from .agents import map_agent
from .config import config
from .retry import with_retries
from .schemas import Chunk, ChunkBrief


_MAX_CHARS_PER_CALL = 24_000  # ~6K tokens; covers a typical chapter


async def map_chunks(slug: str, chunks: list[Chunk]) -> dict[str, ChunkBrief]:
    """Run the map pass, reusing on-disk briefs where present.

    Returns the full {chunk_id: ChunkBrief} map, regardless of whether each
    came from cache or a fresh LLM call.
    """
    sem = asyncio.Semaphore(config.map_parallelism)
    valid_ids = {c.id for c in chunks}
    # Filter to current chunk set so stale briefs from prior runs (chunker
    # uses random UUIDs, so re-running yields different ids) don't pollute
    # the result. Failed-marker briefs are also dropped here so they retry.
    results: dict[str, ChunkBrief] = {
        cid: b for cid, b in persist.read_all_briefs(slug).items() if cid in valid_ids
    }

    todo = [c for c in chunks if c.id not in results]
    if not todo:
        print(f"[map] all {len(chunks)} briefs already on disk — skipping LLM")
        return results

    print(f"[map] {len(results)} cached / {len(todo)} to compute "
          f"(parallel={config.map_parallelism})")

    completed = 0
    total = len(todo)
    lock = asyncio.Lock()

    async def _one(chunk: Chunk) -> None:
        nonlocal completed
        async with sem:
            text = chunk.text[:_MAX_CHARS_PER_CALL]
            prompt = (
                f"Chapter: {chunk.chapter_title or '(untitled)'}\n"
                f"Pages {chunk.page_start}-{chunk.page_end}\n\n"
                f"{text}"
            )
            try:
                run = await with_retries(
                    lambda: map_agent.run(prompt),
                    label=f"map[{chunk.id}]",
                )
                brief = run.output
            except Exception as exc:  # noqa: BLE001 — single chunk, log + degrade
                brief = ChunkBrief(
                    summary_1line=f"[map failed: {type(exc).__name__}]",
                    importance=0.1,
                )
            persist.write_brief(slug, chunk.id, brief)
            results[chunk.id] = brief
        async with lock:
            completed += 1
            if completed % 10 == 0 or completed == total:
                print(f"[map] {completed}/{total}")

    await asyncio.gather(*(_one(c) for c in todo))
    return results
