"""Phase 4 — pick K illustration prompts that *spread across the book*.

The naive approach (rank globally by `importance * visual_strength`,
take top K) clusters every image into the 1-7 highest-importance
chunks, leaving the other 25-30 chapters text-only. That kills reading
momentum: a reader scrolls through chapter after chapter with no
visual anchor.

This module instead picks scenes in three passes:

  1. **Coverage pass** — give every chunk that has at least one
     candidate scene exactly one image, in score order. This guarantees
     no chapter ends up text-only when there's something paintable in it.
     We stop the coverage pass at min(budget, n_chunks_with_candidates).

  2. **Pacing pass** — until the budget is filled, hand out a second
     image to chunks that scored highest, but never let any chunk
     exceed `max_per_chunk` (default 2). This concentrates the *extra*
     budget on the peaks without abandoning the valleys.

  3. **Tie-break** — within a chunk, pick scenes by visual_strength so
     the cinematic composition that was tagged 'wide' or 'establishing'
     wins over a third repetitive close-up.

No LLM calls. Pure ranking + bucketing.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass

from .schemas import Chunk, ChunkBrief, ChunkDeep, SceneBrief


@dataclass(frozen=True)
class PlannedScene:
    scene_id: str
    chunk_id: str
    chapter_title: str | None
    scene_text: str
    score: float
    # Cinematic hints from SceneBrief — image-gen folds these into the
    # prompt. All optional so old plan.json files still parse if they
    # ever flow back into PlannedScene construction.
    mood: str | None = None
    composition: str | None = None
    time_of_day: str | None = None
    setting: str | None = None
    characters_present: tuple[str, ...] = ()
    palette_hint: str | None = None


def plan_scenes(
    chunks: dict[str, Chunk],
    briefs: dict[str, ChunkBrief],
    deeps: dict[str, ChunkDeep],
    *,
    budget: int,
    max_per_chunk: int = 2,
) -> list[PlannedScene]:
    """Select up to `budget` scenes spread across chunks.

    Args:
      chunks: every chunk in the book (used for chapter titles + ordering).
      briefs: per-chunk map output (importance + image_candidates).
      deeps:  per-chunk reduce output (top_scenes) for high-importance chunks.
      budget: target number of illustrations.
      max_per_chunk: cap on how many scenes any single chunk can keep.
        Default 2 — one image at the top of the chapter, one mid-chapter
        anchor is enough to keep momentum without bloating one chapter.

    Returns the chosen scenes in **chunk-document order** so downstream
    consumers (delta builder, bundler) see them in reading order.
    """
    # Build the candidate pool: every scene from every chunk.
    candidates_by_chunk: dict[str, list[PlannedScene]] = {}
    for chunk_id, chunk in chunks.items():
        importance = briefs[chunk_id].importance if chunk_id in briefs else 0.3

        scene_pool: list[SceneBrief] = []
        if chunk_id in deeps:
            scene_pool.extend(deeps[chunk_id].top_scenes)
        if chunk_id in briefs:
            scene_pool.extend(briefs[chunk_id].image_candidates)
        if not scene_pool:
            continue

        for scene in scene_pool:
            ps = PlannedScene(
                scene_id=uuid.uuid4().hex[:12],
                chunk_id=chunk_id,
                chapter_title=chunk.chapter_title,
                scene_text=scene.scene_text,
                score=importance * scene.visual_strength,
                mood=scene.mood,
                composition=scene.composition,
                time_of_day=scene.time_of_day,
                setting=scene.setting,
                characters_present=tuple(scene.characters_present or ()),
                palette_hint=scene.palette_hint,
            )
            candidates_by_chunk.setdefault(chunk_id, []).append(ps)

    if not candidates_by_chunk:
        return []

    # Sort each chunk's pool by its own score, descending — so the
    # first item we pick from a chunk is its strongest scene, and the
    # second is the next-best with a different composition when
    # possible (see _pick_next).
    for chunk_id, items in candidates_by_chunk.items():
        items.sort(key=lambda s: s.score, reverse=True)

    chosen: list[PlannedScene] = []
    per_chunk_count: dict[str, int] = {cid: 0 for cid in candidates_by_chunk}

    # Pass 1 — coverage. One image per chunk, in *score order across
    # chunks* so the strongest chunk grabs its slot first (this
    # matters when budget < n_chunks_with_candidates).
    chunk_top_score = sorted(
        candidates_by_chunk.items(),
        key=lambda kv: kv[1][0].score,
        reverse=True,
    )
    for chunk_id, items in chunk_top_score:
        if len(chosen) >= budget:
            break
        chosen.append(items[0])
        per_chunk_count[chunk_id] = 1

    # Pass 2 — pacing. Refill the budget by going back to the
    # highest-scoring chunks and granting them up to `max_per_chunk`
    # scenes. Pick the next scene that uses a *different composition*
    # from what we already chose for that chunk so the chapter doesn't
    # show two near-identical images.
    while len(chosen) < budget:
        progress = False
        for chunk_id, items in chunk_top_score:
            if per_chunk_count[chunk_id] >= max_per_chunk:
                continue
            if per_chunk_count[chunk_id] >= len(items):
                continue
            picked = _pick_next(items, taken=per_chunk_count[chunk_id], chosen=chosen, chunk_id=chunk_id)
            if picked is None:
                continue
            chosen.append(picked)
            per_chunk_count[chunk_id] += 1
            progress = True
            if len(chosen) >= budget:
                break
        if not progress:
            break  # nothing left to fill the budget with — bail.

    # Return in document order so chunks 1..N produce images in the
    # right reading sequence.
    chunk_order = {cid: idx for idx, cid in enumerate(chunks.keys())}
    chosen.sort(
        key=lambda s: (
            chunk_order.get(s.chunk_id, 10_000),
            -s.score,  # within a chunk, strongest first
        ),
    )
    return chosen


def _pick_next(
    items: list[PlannedScene],
    *,
    taken: int,
    chosen: list[PlannedScene],
    chunk_id: str,
) -> PlannedScene | None:
    """Pick the next scene from `items[taken:]` that ideally uses a
    different `composition` from scenes already chosen in this chunk.

    Falls back to the next-by-score scene if no composition diversity
    is available."""
    already_compositions = {
        s.composition for s in chosen if s.chunk_id == chunk_id and s.composition
    }
    fallback: PlannedScene | None = None
    for s in items[taken:]:
        if fallback is None:
            fallback = s
        if s.composition and s.composition not in already_compositions:
            return s
    return fallback
