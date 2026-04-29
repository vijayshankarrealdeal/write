"""Phase 3 — gated deep pass on the highest-importance chunks.

Same per-item persistence as the map pass: each chunk's deep result is
written to `deeps/<chunk_id>.json` immediately, so a crash mid-pass loses
only the in-flight work.
"""

from __future__ import annotations

import asyncio

from . import persist
from .agents import reduce_agent
from .config import config
from .retry import with_retries
from .schemas import Chunk, ChunkBrief, ChunkDeep, HighlightSpan


_MAX_CHARS_PER_CALL = 40_000  # bigger budget — smarter model, fewer calls


def pick_top_chunks(
    briefs: dict[str, ChunkBrief],
    *,
    top_fraction: float | None = None,
) -> list[str]:
    fraction = top_fraction if top_fraction is not None else config.reduce_top_fraction
    if not briefs:
        return []
    ranked = sorted(briefs.items(), key=lambda kv: kv[1].importance, reverse=True)
    n = max(1, int(round(len(ranked) * fraction)))
    return [chunk_id for chunk_id, _ in ranked[:n]]


async def reduce_chunks(
    slug: str,
    chunks: dict[str, Chunk],
    chunk_ids: list[str],
    *,
    reader_preference: str | None = None,
) -> dict[str, ChunkDeep]:
    sem = asyncio.Semaphore(config.reduce_parallelism)
    wanted = set(chunk_ids)
    results: dict[str, ChunkDeep] = {
        cid: d for cid, d in persist.read_all_deeps(slug).items() if cid in wanted
    }

    todo = [cid for cid in chunk_ids if cid not in results]
    if not todo:
        print(f"[reduce] all {len(chunk_ids)} deeps cached — skipping LLM")
        return results

    print(f"[reduce] {len(results)} cached / {len(todo)} to compute")

    completed = 0
    total = len(todo)
    lock = asyncio.Lock()

    async def _one(chunk_id: str) -> None:
        nonlocal completed
        chunk = chunks.get(chunk_id)
        if chunk is None:
            return
        async with sem:
            text = chunk.text[:_MAX_CHARS_PER_CALL]
            preference_line = (
                f"Reader preference (bias scene + highlight picks toward this): "
                f"{reader_preference}\n\n"
                if reader_preference
                else ""
            )
            prompt = (
                f"Chapter: {chunk.chapter_title or '(untitled)'}\n"
                f"Pages {chunk.page_start}-{chunk.page_end}\n\n"
                f"{preference_line}"
                f"<<<TEXT START>>>\n{text}\n<<<TEXT END>>>"
            )
            try:
                run = await with_retries(
                    lambda: reduce_agent.run(prompt),
                    label=f"reduce[{chunk_id}]",
                )
                deep = _validate_spans(run.output, text)
            except Exception as exc:  # noqa: BLE001
                deep = ChunkDeep(rich_summary=f"[reduce failed: {type(exc).__name__}]")
            persist.write_deep(slug, chunk_id, deep)
            results[chunk_id] = deep
        async with lock:
            completed += 1
            if completed % 5 == 0 or completed == total:
                print(f"[reduce] {completed}/{total}")

    await asyncio.gather(*(_one(cid) for cid in todo))
    return results


def _validate_spans(deep: ChunkDeep, text: str) -> ChunkDeep:
    """Drop spans whose offsets don't land on real characters of `text`."""
    valid: list[HighlightSpan] = []
    n = len(text)
    for span in deep.highlight_spans:
        if 0 <= span.start < n and span.length > 0 and span.start + span.length <= n:
            valid.append(span)
    return deep.model_copy(update={"highlight_spans": valid})
