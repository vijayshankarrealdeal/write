"""Manual sync: take a previously-ingested book on disk and push it to
Postgres + MinIO.

Run *after* `ingest_book.py` has finished and you've eyeballed the output
folder. This script is intentionally separate so the user controls when
the side-effects happen.

    python sync_to_db.py bible

What it does:
  1. Loads `storage/books/<slug>/manifest.json` and the per-chunk JSONs.
  2. Uploads every PNG under `images/` to MinIO under
     `books/<slug>/<scene_id>.png` and records the public URL.
  3. Rebuilds the Quill Delta for each section, swapping local file paths
     for the MinIO public URLs.
  4. Creates a random author user, inserts `Writing` + N `Section`s,
     picks a random publisher user, inserts a `FeedItem`.
  5. Writes the resulting IDs back into `manifest.synced` so re-running
     is a no-op (or use `--force` to publish a second copy).

Idempotent unless `--force` is passed.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_BACKEND_ROOT = _HERE.parent
if str(_BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(_BACKEND_ROOT))

from book_ingest import persist  # noqa: E402
from book_ingest.image_planner import PlannedScene  # noqa: E402
from book_ingest.schemas import (  # noqa: E402
    Chunk,
    ChunkBrief,
    ChunkDeep,
    GeneratedScene,
)


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Sync a locally-ingested book to MinIO + Postgres.")
    p.add_argument("slug", help="Folder name under storage/books/ (e.g. 'bible').")
    p.add_argument("--force", action="store_true",
                   help="Publish a fresh copy even if already synced.")
    p.add_argument("--no-images", action="store_true",
                   help="Skip MinIO upload (use local file:// URLs in deltas; "
                        "useful for dry runs).")
    return p.parse_args()


async def _main() -> int:
    args = _parse_args()
    slug = args.slug

    book_dir = persist.book_dir(slug)
    manifest = persist.read_manifest(slug)
    if not manifest:
        print(f"No manifest at {book_dir}/manifest.json — has the book been ingested?",
              file=sys.stderr)
        return 2

    if manifest.get("synced") and not args.force:
        print(f"Already synced: {manifest['synced']}\nPass --force to publish again.")
        return 0

    chunks, briefs, deeps, scenes_by_chunk_local = _load_artifacts(slug)
    if not chunks:
        print("No chunks on disk — nothing to sync.", file=sys.stderr)
        return 2

    # ---- upload images to MinIO ----
    image_url_for_path: dict[str, str] = {}
    if args.no_images:
        image_url_for_path = {
            gs.image_path: Path(gs.image_path).resolve().as_uri()
            for pairs in scenes_by_chunk_local.values()
            for _, gs in pairs
        }
    else:
        image_url_for_path = await _upload_images(slug, scenes_by_chunk_local)

    def url_for(local_path: str) -> str:
        return image_url_for_path.get(local_path, Path(local_path).resolve().as_uri())

    # ---- DB publish ----
    from book_ingest import db_publish  # lazy: avoids importing app.* on dry runs

    # Prefer the dedicated poster cover (manifest.cover_image_local)
    # — that's a purpose-built jacket image. Fall back to the
    # highest-scoring chunk scene if the poster phase didn't run.
    cover_local = manifest.get("cover_image_local") or _pick_cover(scenes_by_chunk_local)
    cover_url: str | None = None
    if cover_local and Path(cover_local).exists():
        if args.no_images:
            cover_url = Path(cover_local).resolve().as_uri()
        else:
            from app.storage import upload_file  # type: ignore[import-not-found]
            with open(cover_local, "rb") as fh:
                data = fh.read()
            cover_url = await upload_file(
                f"books/{slug}/cover.png",
                data,
                content_type="image/png",
            )

    # Pipeline-published works are owned by the canonical "inkspace"
    # account so they show up in the editorial profile alongside
    # Mahabharata, Ramayana, etc. The book's *real* author (e.g. Mary
    # Wollstonecraft Shelley) stays in `writings.author` and is what the
    # reader sees on the detail page.
    cleaned_md_map = _build_cleaned_markdown_map(slug, chunks)
    poster = manifest.get("poster") or {}
    db_ids = await db_publish.publish_book(
        title=manifest["title"],
        author=manifest.get("author"),
        description=manifest.get("description") or poster.get("back_cover_copy"),
        cover_image_path=cover_url,
        chunks=chunks,
        briefs=briefs,
        deeps=deeps,
        scenes_by_chunk=scenes_by_chunk_local,
        image_url_for=url_for,
        cleaned_markdown=cleaned_md_map,
        primary_account_email="inkspacex@inkspacex.com",
        primary_account_name="inkspace",
        genres=poster.get("genres") or [],
        writing_types=poster.get("writing_types") or ["book"],
        tags=poster.get("tags") or [],
    )

    manifest["synced"] = db_ids
    persist.write_manifest(slug, manifest)

    print(json.dumps({"slug": slug, "synced": db_ids}, indent=2))
    return 0


def _build_cleaned_markdown_map(slug: str, chunks: list[Chunk]) -> dict[str, str]:
    """Per-chunk clean markdown for the Delta builder, so flutter_quill
    renders headings/italics/blockquote properly instead of dumping raw
    `## Letter 1` and `*italic*` text.

    HTML books skipped the cleaner phase, so `chunk.text` IS the clean
    markdown — use it directly. PDF books have a parallel `cleaned/<id>.md`
    file written by the cleaner phase. Falls back to chunk.text if
    cleaned markdown isn't present (e.g. cleaner failed for one chunk).
    """
    book = persist.book_dir(slug)
    cleaned_dir = book / "cleaned"
    out: dict[str, str] = {}
    for c in chunks:
        cleaned_path = cleaned_dir / f"{c.id}.md"
        if cleaned_path.exists() and cleaned_path.stat().st_size > 0:
            try:
                out[c.id] = cleaned_path.read_text(encoding="utf-8")
                continue
            except OSError:
                pass
        # HTML path or PDF cleaner-skipped path — chunk.text is markdown.
        out[c.id] = c.text
    return out


# -----------------------------------------------------------------------
# Loaders
# -----------------------------------------------------------------------

def _load_artifacts(
    slug: str,
) -> tuple[
    list[Chunk],
    dict[str, ChunkBrief],
    dict[str, ChunkDeep],
    dict[str, list[tuple[PlannedScene, GeneratedScene]]],
]:
    book = persist.book_dir(slug)
    chunks: list[Chunk] = []
    briefs: dict[str, ChunkBrief] = {}
    deeps: dict[str, ChunkDeep] = {}

    for path in sorted((book / "chunks").glob("*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        chunk = Chunk.model_validate(payload["chunk"])
        chunks.append(chunk)
        if payload.get("brief"):
            briefs[chunk.id] = ChunkBrief.model_validate(payload["brief"])
        if payload.get("deep"):
            deeps[chunk.id] = ChunkDeep.model_validate(payload["deep"])

    # Restore chunk order — they were written in chapter order during ingest;
    # fall back to page_start sort for safety.
    chunks.sort(key=lambda c: (c.page_start, c.page_end))

    plan_path = book / "plan.json"
    plan_by_scene: dict[str, PlannedScene] = {}
    if plan_path.exists():
        for entry in json.loads(plan_path.read_text(encoding="utf-8")):
            plan_by_scene[entry["scene_id"]] = PlannedScene(
                scene_id=entry["scene_id"],
                chunk_id=entry["chunk_id"],
                chapter_title=entry.get("chapter_title"),
                scene_text=entry["scene_text"],
                score=float(entry.get("score", 0.0)),
            )

    scenes_by_chunk: dict[str, list[tuple[PlannedScene, GeneratedScene]]] = {}
    for meta_path in sorted((book / "images").glob("*.json")):
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        # Skip the book-cover meta — it has chunk_id=null because no chunk
        # owns it. The cover is referenced via manifest.cover_image_local
        # and uploaded separately by the caller, not via scenes_by_chunk.
        if meta.get("is_cover") or meta.get("chunk_id") is None:
            continue
        scene_id = meta["scene_id"]
        chunk_id = meta["chunk_id"]
        local_image = meta.get("image_path")
        if not local_image or not Path(local_image).exists():
            # PNG missing — skip silently; the agent may have failed on this scene.
            continue
        gs = GeneratedScene(
            scene_id=scene_id,
            chunk_id=chunk_id,
            prompt=meta.get("prompt", ""),
            image_path=local_image,
        )
        ps = plan_by_scene.get(scene_id) or PlannedScene(
            scene_id=scene_id,
            chunk_id=chunk_id,
            chapter_title=meta.get("chapter_title"),
            scene_text=meta.get("scene_text", ""),
            score=float(meta.get("score", 0.0)),
        )
        scenes_by_chunk.setdefault(chunk_id, []).append((ps, gs))

    # Sort scenes within a chunk by score (highest first) so the cover
    # image and the in-line image both feel like the chapter's headline shot.
    for chunk_id in scenes_by_chunk:
        scenes_by_chunk[chunk_id].sort(key=lambda pair: pair[0].score, reverse=True)

    return chunks, briefs, deeps, scenes_by_chunk


def _pick_cover(
    scenes_by_chunk: dict[str, list[tuple[PlannedScene, GeneratedScene]]],
) -> str | None:
    best: tuple[float, str] | None = None
    for pairs in scenes_by_chunk.values():
        for planned, scene in pairs:
            if best is None or planned.score > best[0]:
                best = (planned.score, scene.image_path)
    return best[1] if best else None


# -----------------------------------------------------------------------
# MinIO upload
# -----------------------------------------------------------------------

async def _upload_images(
    slug: str,
    scenes_by_chunk: dict[str, list[tuple[PlannedScene, GeneratedScene]]],
) -> dict[str, str]:
    """Upload every PNG to MinIO under `books/<slug>/<scene_id>.png`. Returns
    {local_path: public_url}."""
    from app.storage import upload_file  # lazy: requires miniopy_async

    out: dict[str, str] = {}

    async def _put(local_path: str, scene_id: str) -> None:
        with open(local_path, "rb") as fh:
            data = fh.read()
        url = await upload_file(
            f"books/{slug}/{scene_id}.png",
            data,
            content_type="image/png",
        )
        out[local_path] = url

    tasks: list[asyncio.Task] = []
    for pairs in scenes_by_chunk.values():
        for _, gs in pairs:
            tasks.append(asyncio.create_task(_put(gs.image_path, gs.scene_id)))
    if tasks:
        await asyncio.gather(*tasks)
    print(f"[minio] uploaded {len(out)} images")
    return out


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
