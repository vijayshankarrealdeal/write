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
import re
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
    #
    # The manifest stores `cover_image_local` as the absolute path on the
    # machine that ran the pipeline. When sync_to_db runs on a different
    # host (e.g. inside the Docker container after vm-publish), that path
    # doesn't exist. Resolve relative to the *current* book_dir first;
    # only fall back to the manifest path if the conventional location
    # is empty.
    conventional_cover = book_dir / "images" / "cover.png"
    if conventional_cover.exists():
        cover_local: str | None = str(conventional_cover)
    else:
        cover_local = manifest.get("cover_image_local") or _pick_cover(scenes_by_chunk_local)
    cover_url: str | None = None
    cover_image_meta: dict | None = None
    if cover_local and Path(cover_local).exists():
        if args.no_images:
            cover_url = Path(cover_local).resolve().as_uri()
        else:
            # Run the cover through the platform's image pipeline so the
            # feed card has blurhash placeholder + dominant color +
            # size variants — same shape every other cover in the app
            # carries. Without this, the feed card has no aspect-ratio
            # hint and renders with a grey placeholder.
            from app.image_pipeline import process_image  # type: ignore[import-not-found]
            from app.storage import upload_variants  # type: ignore[import-not-found]
            with open(cover_local, "rb") as fh:
                cover_bytes = fh.read()
            variants, meta = await process_image(cover_bytes)
            # Path-version the upload so the URL is immutable and
            # cacheable — different cover regenerations don't collide.
            import time as _t
            version = int(_t.time())
            base_path = f"books/{slug}/cover/{version}"
            base_url = await upload_variants(base_path, variants)
            meta["base_url"] = base_url
            cover_image_meta = meta
            # Pick the medium variant URL for the legacy cover_image_path
            # field (used by older readers / fallbacks).
            cover_url = f"{base_url}/medium.webp"

    # Pipeline-published works are owned by the canonical "inkspace"
    # account so they show up in the editorial profile alongside
    # Mahabharata, Ramayana, etc. The book's *real* author (e.g. Mary
    # Wollstonecraft Shelley) stays in `writings.author` and is what the
    # reader sees on the detail page.
    cleaned_md_map = _build_cleaned_markdown_map(slug, chunks)
    poster = manifest.get("poster") or {}
    # Older manifests (created by the studio's upload stub before the
    # pipeline backfill landed) may be missing top-level metadata. Fall
    # back to the poster fields, then to a prettified slug, so a stale
    # manifest doesn't block the publish.
    title_value = (
        manifest.get("title")
        or manifest.get("title_raw")
        or poster.get("title")
        or _title_from_slug(slug)
    )
    description_value = (
        manifest.get("description")
        or poster.get("description")
    )
    characters = await _build_characters_payload(
        slug, manifest=manifest, no_images=args.no_images
    )
    db_ids = await db_publish.publish_book(
        title=title_value,
        author=manifest.get("author"),
        description=description_value,
        cover_image_path=cover_url,
        cover_image_meta=cover_image_meta,
        chunks=chunks,
        briefs=briefs,
        deeps=deeps,
        scenes_by_chunk=scenes_by_chunk_local,
        image_url_for=url_for,
        cleaned_markdown=cleaned_md_map,
        # Canonical inkspace identity — same email/password every run so
        # the smoke-test curl commands and the Flutter app can both log in
        # to confirm uploads landed.
        primary_account_email=db_publish.INKSPACE_EMAIL,
        primary_account_name=db_publish.INKSPACE_NAME,
        primary_account_password=db_publish.INKSPACE_PASSWORD,
        genres=poster.get("genres") or [],
        writing_types=poster.get("writing_types") or ["book"],
        tags=poster.get("tags") or [],
        visibility="public",
        characters=characters,
    )

    manifest["synced"] = db_ids
    persist.write_manifest(slug, manifest)

    print(json.dumps({"slug": slug, "synced": db_ids}, indent=2))
    return 0


import re as _re
_LEADING_H2_RE = _re.compile(r"\A\s*##\s[^\n]*\n+", _re.MULTILINE)
_LEADING_NUM_RE = _re.compile(r"^\d+[-_]")


def _title_from_slug(slug: str) -> str:
    """Last-resort title fallback: turn '00084-frankenstein-or-the-modern-prometheus'
    into 'Frankenstein Or The Modern Prometheus'. Strips a leading numeric
    prefix from Project Gutenberg-style filenames."""
    base = _LEADING_NUM_RE.sub("", slug)
    return base.replace("-", " ").replace("_", " ").strip().title() or slug


def _strip_leading_h2(md: str) -> str:
    """Drop a leading `## Some Heading` from the markdown.

    The Flutter app shows `Section.title` as an italic header at the top
    of each section, so embedding the same heading inside the section's
    Delta body shows the chapter title twice. The HTML loader emits
    `## Letter 1` at the start of each chapter's markdown — useful for
    the standalone preview .md files but redundant once the chapter is
    a Section in the app.
    """
    return _LEADING_H2_RE.sub("", md, count=1)


def _build_cleaned_markdown_map(slug: str, chunks: list[Chunk]) -> dict[str, str]:
    """Per-chunk clean markdown for the Delta builder, so flutter_quill
    renders headings/italics/blockquote properly instead of dumping raw
    `## Letter 1` and `*italic*` text.

    HTML books skipped the cleaner phase, so `chunk.text` IS the clean
    markdown — use it directly. PDF books have a parallel `cleaned/<id>.md`
    file written by the cleaner phase. Falls back to chunk.text if
    cleaned markdown isn't present (e.g. cleaner failed for one chunk).

    The leading `## Heading` line is stripped from each chunk so the
    Flutter app's Section.title rendering doesn't duplicate it in the
    body.
    """
    book = persist.book_dir(slug)
    cleaned_dir = book / "cleaned"
    out: dict[str, str] = {}
    for c in chunks:
        cleaned_path = cleaned_dir / f"{c.id}.md"
        md: str | None = None
        if cleaned_path.exists() and cleaned_path.stat().st_size > 0:
            try:
                md = cleaned_path.read_text(encoding="utf-8")
            except OSError:
                md = None
        if md is None:
            # HTML path or PDF cleaner-skipped path — chunk.text is markdown.
            md = c.text
        out[c.id] = _strip_leading_h2(md)
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
                mood=entry.get("mood"),
                composition=entry.get("composition"),
                time_of_day=entry.get("time_of_day"),
                setting=entry.get("setting"),
                characters_present=tuple(entry.get("characters_present") or ()),
                palette_hint=entry.get("palette_hint"),
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
        # Drop scenes left over from a previous plan (planner uses random
        # uuid scene_ids, so re-running the planner orphans the old PNGs).
        # Only embed scenes that the *current* plan.json references —
        # otherwise the app shows duplicate / stale illustrations from
        # earlier runs clustered on the same chunks.
        if plan_by_scene and scene_id not in plan_by_scene:
            continue
        chunk_id = meta["chunk_id"]
        # Resolve relative to the *current* book_dir first — the meta's
        # `image_path` is the absolute path of the machine that ran the
        # pipeline and won't exist if sync runs on a different host
        # (e.g. inside the Docker container after vm-publish). Convention
        # is `images/{scene_id}.png`, written by the image-gen phase.
        conventional = book / "images" / f"{scene_id}.png"
        if conventional.exists():
            local_image = str(conventional)
        else:
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


_CHAR_SAFE_NAME_RE = re.compile(r"[^a-z0-9]+")


def _safe_char_slug(name: str) -> str:
    """Filesystem / URL slug for a character name. Matches the
    `character_sheets._safe_name` shape so paths align with the
    on-disk portrait filenames."""
    return _CHAR_SAFE_NAME_RE.sub("-", name.lower()).strip("-") or "character"


async def _build_characters_payload(
    slug: str,
    *,
    manifest: dict,
    no_images: bool,
) -> list[dict]:
    """Process each character portrait through the platform image
    pipeline and return the per-character publish payload.

    Idempotent under re-publish: the file paths are versioned with
    `int(time.time())`, so a re-run uploads to a new prefix and the
    DB row points at the latest. Old prefixes are orphaned but
    harmless (immutable MinIO objects).

    Returns [] when the book has no character bible — callers pass
    that through to `publish_book(characters=[])` and the cast table
    gets zero rows.
    """
    bible = (manifest.get("scout") or {}).get("character_bible") or []
    if not bible:
        return []
    sheets = manifest.get("character_sheets") or {}

    import time as _t
    book = persist.book_dir(slug)
    out: list[dict] = []
    for idx, entry in enumerate(bible):
        if not isinstance(entry, dict):
            continue
        name = (entry.get("name") or "").strip()
        appearance = (entry.get("appearance") or "").strip()
        if not name or not appearance:
            continue
        portrait_path = _resolve_portrait_path(book, name, sheets.get(name))
        image_url: str | None = None
        image_meta: dict | None = None
        if portrait_path is not None and not no_images:
            try:
                from app.image_pipeline import process_image  # type: ignore[import-not-found]
                from app.storage import upload_variants  # type: ignore[import-not-found]
                data = portrait_path.read_bytes()
                variants, meta = await process_image(data)
                version = int(_t.time())
                base_path = f"books/{slug}/characters/{_safe_char_slug(name)}/{version}"
                base_url = await upload_variants(base_path, variants)
                meta["base_url"] = base_url
                image_meta = meta
                image_url = f"{base_url}/medium.webp"
            except Exception as exc:  # noqa: BLE001
                print(f"[chars/upload] {name!r} failed: "
                      f"{type(exc).__name__}: {exc} — proceeding without portrait")
        out.append({
            "name": name,
            "appearance": appearance,
            "image_url": image_url,
            "image_meta": image_meta,
            "sort_order": idx,
        })
    return out


def _resolve_portrait_path(
    book_dir: Path,
    name: str,
    manifest_path: str | None,
) -> Path | None:
    """Find a character's portrait PNG on disk.

    The manifest records the absolute path from the host that ran the
    ingest pipeline — when sync runs on a different host (e.g. inside
    the docker container after vm-publish) that path won't exist.
    Convention is `images/_characters/<safe>.png` under the book dir,
    written by `character_sheets.generate_character_sheets`. Try the
    convention first, then fall back to the manifest path."""
    conventional = book_dir / "images" / "_characters" / f"{_safe_char_slug(name)}.png"
    if conventional.exists() and conventional.stat().st_size > 0:
        return conventional
    if manifest_path:
        legacy = Path(manifest_path)
        if legacy.exists() and legacy.stat().st_size > 0:
            return legacy
    return None


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
