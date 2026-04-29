"""Phase 4 — pick K best illustration prompts globally. No LLM calls.

Score = chunk.importance * scene.visual_strength. Rank, take top K, return
PlannedScene records ready for image_gen to consume.
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


def plan_scenes(
    chunks: dict[str, Chunk],
    briefs: dict[str, ChunkBrief],
    deeps: dict[str, ChunkDeep],
    *,
    budget: int,
) -> list[PlannedScene]:
    candidates: list[PlannedScene] = []

    for chunk_id, chunk in chunks.items():
        importance = briefs[chunk_id].importance if chunk_id in briefs else 0.3

        # Prefer scenes from the deep pass — they're better-considered.
        scene_pool: list[SceneBrief] = []
        if chunk_id in deeps:
            scene_pool.extend(deeps[chunk_id].top_scenes)
        if chunk_id in briefs:
            scene_pool.extend(briefs[chunk_id].image_candidates)

        for scene in scene_pool:
            score = importance * scene.visual_strength
            candidates.append(
                PlannedScene(
                    scene_id=uuid.uuid4().hex[:12],
                    chunk_id=chunk_id,
                    chapter_title=chunk.chapter_title,
                    scene_text=scene.scene_text,
                    score=score,
                )
            )

    candidates.sort(key=lambda s: s.score, reverse=True)
    return candidates[:budget]
