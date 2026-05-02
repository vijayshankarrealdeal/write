"""Orchestrates the ingest pipeline.

Resilience contract — every phase is resumable at the per-item level:

  * Pages: `pages/<n>.json` written via atomic rename.
  * Map briefs: `briefs/<chunk_id>.json` per chunk, written as each
    completes. Resume re-runs only the chunks whose file is missing.
  * Reduce deeps: same pattern under `deeps/<chunk_id>.json`.
  * Embeddings: per-item under `embeddings/{chunk-,scene-}<id>.json`.
  * Images: PNG + meta JSON per scene, atomically.

A power cut, network drop, or Ctrl-C never loses work that already landed
on disk. Restart picks up exactly where it stopped.

The pipeline is filesystem-only — it never touches Postgres or MinIO. Use
`sync_to_db.py` for that, manually, after the dump looks right.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from pathlib import Path

from . import embeddings, persist
from .bundler import write_bundle
from .chunker import chunk_pdf
from .cleaner import clean_chunks
from .config import config
from .html_loader import load_html
from .image_gen import generate_image
from .image_planner import PlannedScene, plan_scenes
from .map_agent import map_chunks
from .pdf_loader import LoadedPdf, load_pdf
from .reduce_agent import pick_top_chunks, reduce_chunks
from .retry import with_retries
from .schemas import Chunk, ChunkBrief, ChunkDeep, GeneratedScene
from .poster import generate_cover_image, generate_poster
from .scout import scout_book


@dataclass
class IngestResult:
    slug: str
    book_dir: str
    n_pages: int
    n_chunks: int
    n_deep: int
    n_images: int
    n_chunk_embeddings: int
    n_scene_embeddings: int


def _phase_done(manifest: dict, name: str) -> bool:
    return name in (manifest.get("phases_done") or [])


def _mark_done(slug: str, manifest: dict, name: str) -> None:
    phases = list(manifest.get("phases_done") or [])
    if name not in phases:
        phases.append(name)
    manifest["phases_done"] = phases
    persist.write_manifest(slug, manifest)


async def ingest_pdf(
    pdf_path: str,
    *,
    title: str | None = None,
    slug: str,
    author: str | None = None,
    description: str | None = None,
    image_budget: int | None = None,
    style: str | None = None,
    reader_preference: str | None = None,
) -> IngestResult:
    """Defaults: when style/reader_preference/image_budget are None, the
    scout phase fills them in based on the actual book content. Pass
    explicit values to override.

    Accepts both PDF (`.pdf`) and Project Gutenberg HTML (`.html`/`.htm`).
    For HTML the loader emits clean markdown directly, so the LLM cleaner
    phase is skipped — saves ~$0.10–0.30/book on a 300-page text.
    """
    # ---- 0: load ----------------------------------------------------------
    ext = Path(pdf_path).suffix.lower()
    is_clean_input = ext in (".html", ".htm")

    print(f"[load] reading {pdf_path}")
    loader_title: str | None = None
    loader_author: str | None = None
    loader_subjects: list[str] = []
    if is_clean_input:
        loaded_html = load_html(pdf_path)
        # Shape-compat: chunker imports LoadedPdf, so wrap.
        loaded = LoadedPdf(pages=loaded_html.pages, toc=list(loaded_html.toc))
        loader_title = loaded_html.title
        loader_author = loaded_html.author
        loader_subjects = loaded_html.subjects or []
    else:
        loaded = load_pdf(pdf_path)

    # Loader-supplied metadata fills in defaults the caller didn't set.
    title = title or loader_title or slug
    author = author or loader_author

    out_dir = persist.book_dir(slug)
    manifest = persist.read_manifest(slug) or {
        "title": title,
        "author": author,
        "description": description,
        "slug": slug,
        "image_budget": image_budget,
        "style": style,
        "reader_preference": reader_preference,
        "subjects": loader_subjects,
        "source_format": "html" if is_clean_input else "pdf",
        "phases_done": [],
    }
    # Track explicit user overrides so the scout doesn't clobber them.
    user_set_style = style is not None
    user_set_pref = reader_preference is not None
    user_set_budget = image_budget is not None
    persist.write_manifest(slug, manifest)

    if not _phase_done(manifest, "load"):
        persist.write_pages(slug, loaded.pages)
        _mark_done(slug, manifest, "load")
    print(f"[load] {len(loaded.pages)} pages, {len(loaded.toc)} TOC entries"
          f"{' (HTML)' if is_clean_input else ''}")

    # ---- 1: chunk ---------------------------------------------------------
    chunks = chunk_pdf(loaded)
    chunks_by_id: dict[str, Chunk] = {c.id: c for c in chunks}
    print(f"[chunk] produced {len(chunks)} chunks")

    # Sweep stale per-item files left behind by older chunker runs (random
    # UUIDs) before the deterministic-ID switch. One-time spike of removals
    # the first time a pre-existing book is re-ingested.
    removed = persist.cleanup_orphans(slug, set(chunks_by_id.keys()))
    if any(removed.values()):
        print(f"[cleanup] orphans removed: {removed}")

    # ---- 1.25: cleaner (rewrite raw PDF text → clean markdown) ----------
    # Runs before scout/map so every downstream phase + the final reader
    # sees readable prose (no mid-sentence line breaks, no OCR cruft).
    # HTML inputs already arrive as clean markdown from html_loader, so
    # this LLM phase is skipped entirely (saves ~$0.10–0.30/book).
    if is_clean_input:
        print(f"[clean] skipped — input is already clean markdown ({ext})")
        _mark_done(slug, manifest, "clean")
    else:
        n_cleaned = await clean_chunks(slug, chunks)
        print(f"[clean] +{n_cleaned} new "
              f"({len(chunks) - n_cleaned} cached / {len(chunks)} total)")
        if all((persist.book_dir(slug) / 'cleaned' / f'{c.id}.md').exists()
               for c in chunks):
            _mark_done(slug, manifest, "clean")

    # ---- 1.5: scout (auto-direct the book's visual voice) ---------------
    # One LLM call that reads samples of the book and proposes:
    #   - illustration style (medium, palette, era)
    #   - whether to bias scene picks toward certain moments
    #   - how many illustrations the book deserves
    # Cached to manifest.scout so re-runs reuse the proposal.
    if "scout" not in (manifest.get("phases_done") or []):
        try:
            print(f"[scout] surveying book…")
            proposal = await scout_book(
                title=title,
                author=author,
                n_pages=len(loaded.pages),
                chunks=chunks,
            )
            manifest["scout"] = proposal.model_dump()
            print(f"[scout] genre: {proposal.detected_genre}")
            print(f"[scout] style: {proposal.suggested_style}")
            if proposal.suggested_reader_preference:
                print(f"[scout] preference: {proposal.suggested_reader_preference}")
            print(f"[scout] budget: {proposal.suggested_image_budget}")
            print(f"[scout] rationale: {proposal.rationale}")
            _mark_done(slug, manifest, "scout")
        except Exception as exc:  # noqa: BLE001
            # Fail open — scout is optional polish, not load-bearing.
            print(f"[scout] failed: {type(exc).__name__}: {exc} — using defaults")

    scout_data = manifest.get("scout") or {}
    if not user_set_style:
        style = scout_data.get("suggested_style") or "editorial illustration, muted palette"
        manifest["style"] = style
    if not user_set_pref and scout_data.get("suggested_reader_preference"):
        reader_preference = scout_data["suggested_reader_preference"]
        manifest["reader_preference"] = reader_preference
    if not user_set_budget:
        image_budget = scout_data.get("suggested_image_budget") or config.default_image_budget
        manifest["image_budget"] = image_budget

    persist.write_manifest(slug, manifest)
    budget = manifest["image_budget"]

    # ---- 2: map (per-chunk persistence; resumable mid-flight) ------------
    briefs: dict[str, ChunkBrief] = await map_chunks(slug, chunks)
    if all(c.id in briefs for c in chunks):
        _mark_done(slug, manifest, "map")

    # ---- 3: reduce (per-chunk persistence; resumable) --------------------
    top_ids = pick_top_chunks(briefs)
    deeps: dict[str, ChunkDeep] = await reduce_chunks(
        slug,
        chunks_by_id,
        top_ids,
        reader_preference=reader_preference,
    )
    if all(cid in deeps for cid in top_ids):
        _mark_done(slug, manifest, "reduce")

    # ---- 3.5: embeddings (per-chunk; cheap; enables /regenerate-image) ---
    n_chunk_emb = await embeddings.embed_chunks(slug, briefs, deeps)
    print(f"[embed/chunks] +{n_chunk_emb} new (cached: {len(briefs) - n_chunk_emb})")
    if all(persist.has_chunk_embedding(slug, cid) for cid in briefs):
        _mark_done(slug, manifest, "chunk_embeddings")

    # ---- 4: plan images ---------------------------------------------------
    planned = plan_scenes(chunks_by_id, briefs, deeps, budget=budget)
    _save_plan(slug, planned)
    print(f"[plan] {len(planned)} scenes selected (budget={budget})")

    # ---- 4.5: scene embeddings (so 'regenerate the storm scene' works) ---
    n_scene_emb = await embeddings.embed_scenes(
        slug,
        ((p.scene_id, p.scene_text) for p in planned),
    )
    print(f"[embed/scenes] +{n_scene_emb} new (cached: {len(planned) - n_scene_emb})")

    # ---- 5: generate images (per-scene; PNG already exists → skip) -------
    scenes = await _generate_all_images(slug, planned, style, reader_preference)
    if all(persist.image_path_for(slug, p.scene_id).exists() for p in planned):
        _mark_done(slug, manifest, "images")
    print(f"[images] {len(scenes)} on disk")

    # ---- 6: persist composite chunks + highlights ------------------------
    scenes_by_chunk: dict[str, list[str]] = {}
    for s in scenes:
        scenes_by_chunk.setdefault(s.chunk_id, []).append(s.scene_id)

    for chunk in chunks:
        persist.write_chunk(
            slug,
            chunk,
            brief=briefs.get(chunk.id),
            deep=deeps.get(chunk.id),
            scene_ids=scenes_by_chunk.get(chunk.id, []),
        )
    persist.write_highlights(slug, deeps)
    _mark_done(slug, manifest, "persist")

    # ---- 6.5: poster (book-jacket metadata + cover image) ---------------
    if "poster" not in (manifest.get("phases_done") or []):
        try:
            print(f"[poster] writing back-cover copy + cover prompt…")
            poster = await generate_poster(
                title=title,
                author=author,
                scout_data=manifest.get("scout"),
                briefs=briefs,
                deeps=deeps,
            )
            manifest["poster"] = poster.model_dump()
            print(f"[poster] genres: {poster.genres}")
            print(f"[poster] tags: {poster.tags}")
            print(f"[poster] cover scene: {poster.cover_scene}")

            cover_path = await generate_cover_image(
                slug,
                cover_scene=poster.cover_scene,
                style=manifest.get("style"),
                reader_preference=manifest.get("reader_preference"),
            )
            if cover_path:
                manifest["cover_image_local"] = str(cover_path)
                print(f"[poster] cover image: {cover_path}")
            persist.write_manifest(slug, manifest)
            _mark_done(slug, manifest, "poster")
        except Exception as exc:  # noqa: BLE001
            print(f"[poster] failed: {type(exc).__name__}: {exc} — DB publish "
                  f"will fall back to scene-based cover and empty metadata")

    # ---- 7: bundle (reproducible replay archive) -------------------------
    # Pack everything that survives DB/MinIO loss into a single zip:
    # manifest + chunks (with cleaned md + briefs + deeps embedded) + plan
    # + highlights + every PNG + per-scene meta + cover + embeddings. A
    # later operator can run `restore_bundle.py <zip>` against a fresh
    # MinIO/Postgres and recreate the exact same Writing without paying
    # for a second LLM/image-gen run.
    try:
        bundle_path, bundle_info = write_bundle(slug)
        manifest["bundle"] = bundle_info
        persist.write_manifest(slug, manifest)
        print(f"[bundle] wrote {bundle_path} "
              f"({bundle_info['size_bytes'] / 1_048_576:.1f} MB, "
              f"{bundle_info['file_count']} files)")
        _mark_done(slug, manifest, "bundle")
    except Exception as exc:  # noqa: BLE001
        print(f"[bundle] failed: {type(exc).__name__}: {exc} — "
              f"sync_to_db.py still works from the on-disk artifacts")

    return IngestResult(
        slug=slug,
        book_dir=str(out_dir),
        n_pages=len(loaded.pages),
        n_chunks=len(chunks),
        n_deep=len(deeps),
        n_images=len(scenes),
        n_chunk_embeddings=sum(1 for cid in briefs if persist.has_chunk_embedding(slug, cid)),
        n_scene_embeddings=sum(1 for p in planned if persist.has_scene_embedding(slug, p.scene_id)),
    )


# ---- helpers ------------------------------------------------------------

def _save_plan(slug: str, planned: list[PlannedScene]) -> None:
    out = persist.book_dir(slug) / "plan.json"
    persist._atomic_write_text(  # type: ignore[attr-defined]
        out,
        json.dumps(
            [
                {
                    "scene_id": p.scene_id,
                    "chunk_id": p.chunk_id,
                    "chapter_title": p.chapter_title,
                    "scene_text": p.scene_text,
                    "score": p.score,
                }
                for p in planned
            ],
            indent=2,
        ),
    )


async def _generate_all_images(
    slug: str,
    planned: list[PlannedScene],
    style: str | None,
    reader_preference: str | None,
) -> list[GeneratedScene]:
    """Resumable per-scene image generation. A scene whose PNG is already
    on disk is skipped and merely loaded back into the result list."""
    sem = asyncio.Semaphore(config.image_parallelism)
    scenes: list[GeneratedScene] = []
    lock = asyncio.Lock()
    completed = 0
    cached = 0

    async def _one(p: PlannedScene) -> GeneratedScene | None:
        nonlocal completed, cached
        out_path = persist.image_path_for(slug, p.scene_id)
        if out_path.exists() and out_path.stat().st_size > 0:
            async with lock:
                cached += 1
            return GeneratedScene(
                scene_id=p.scene_id,
                chunk_id=p.chunk_id,
                prompt=p.scene_text,
                image_path=str(out_path),
            )

        async with sem:
            try:
                await with_retries(
                    lambda: generate_image(
                        p.scene_text,
                        str(out_path),
                        style=style,
                        reader_preference=reader_preference,
                    ),
                    label=f"image[{p.scene_id}]",
                )
            except Exception as exc:  # noqa: BLE001
                print(f"[images] {p.scene_id} failed: {exc}")
                return None
        scene = GeneratedScene(
            scene_id=p.scene_id,
            chunk_id=p.chunk_id,
            prompt=p.scene_text,
            image_path=str(out_path),
        )
        persist.write_scene_meta(slug, scene, p)
        async with lock:
            completed += 1
            if completed % 5 == 0:
                print(f"[images] {completed} new / {cached} cached")
        return scene

    tasks = [_one(p) for p in planned]
    for coro in asyncio.as_completed(tasks):
        s = await coro
        if s is not None:
            scenes.append(s)
    return scenes
