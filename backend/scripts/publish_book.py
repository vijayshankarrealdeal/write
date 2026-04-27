"""Production-side book publisher.

Runs INSIDE the running `fastapi` container on the production VM, where
DATABASE_URL + MINIO_* env vars already point at the internal Postgres
and MinIO. Reads a book bundle (manifest + chunks + images) prepared by
the local studio, uploads images to MinIO, creates the InkSpaceX
editorial user (idempotent), and inserts Writing + Sections + FeedItem.

Bundle layout expected at <bundle-dir>:

    bundle/
        book_ingest/                  # full package, copied as-is from test_model/
        storage/books/<slug>/
            manifest.json
            chunks/<chunk_id>.json
            images/<scene_id>.png
            images/<scene_id>.json
            ...

Usage from the host:

    docker compose cp <bundle.tgz> fastapi:/tmp/bundle.tgz
    docker compose exec fastapi bash -c "
        mkdir -p /tmp/bundle && tar xzf /tmp/bundle.tgz -C /tmp/bundle &&
        cd /tmp/bundle && python /app/scripts/publish_book.py <slug> \\
            --bundle-root /tmp/bundle \\
            --account-email inkspacex@inkspacex.com \\
            --account-name InkSpaceX
    "

Idempotent: re-running with the same `--account-email` reuses the user
account; with the same slug + same DB, this script will warn that a
Writing already exists and exit non-zero unless `--force` is passed.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path


def _setup_paths(bundle_root: Path) -> None:
    """Make `book_ingest` importable from the bundle, and `app.*` importable
    from the running container's /app. Both must work simultaneously."""
    candidates = [
        bundle_root,                    # for `import book_ingest`
        Path("/app"),                   # for `import app`
        Path(__file__).resolve().parents[1],  # backend/ if running outside docker
    ]
    for p in candidates:
        if p.is_dir() and str(p) not in sys.path:
            sys.path.insert(0, str(p))


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Publish a pre-ingested book to production InkSpaceX.")
    p.add_argument("slug", help="Book slug (folder name under storage/books/).")
    p.add_argument("--bundle-root", default="/tmp/bundle",
                   help="Path that contains storage/ and book_ingest/.")
    p.add_argument("--account-email", default="inkspacex@inkspacex.com",
                   help="Email for the editorial publishing account (find-or-create).")
    p.add_argument("--account-name", default="InkSpaceX",
                   help="Display name for the editorial account.")
    p.add_argument("--account-password", default=None,
                   help="If set, bcrypt-hash this and store on the user so the "
                        "account can log in. Updates password on re-runs.")
    p.add_argument("--account-avatar", default=None,
                   help="Path to a local image (PNG/JPG). Uploaded to MinIO and "
                        "set as the user's photo_url.")
    p.add_argument("--force", action="store_true",
                   help="Re-publish even if a Writing with this title already exists.")
    p.add_argument("--no-images", action="store_true",
                   help="Skip MinIO upload; use file:// URLs (debug only).")
    return p.parse_args()


async def _main() -> int:
    args = _parse_args()
    bundle = Path(args.bundle_root).resolve()
    if not bundle.is_dir():
        print(f"Bundle root not found: {bundle}", file=sys.stderr)
        return 2

    _setup_paths(bundle)

    # Lazy imports — paths must be set first.
    from book_ingest import persist  # noqa: E402
    from book_ingest.image_planner import PlannedScene  # noqa: E402
    from book_ingest.schemas import (  # noqa: E402
        Chunk,
        ChunkBrief,
        ChunkDeep,
        GeneratedScene,
    )
    from book_ingest import db_publish  # noqa: E402
    from sqlalchemy import select  # noqa: E402
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine  # noqa: E402

    from app.config import settings  # noqa: E402
    from app.models.writing import Writing  # noqa: E402

    # The studio writes books under <storage_root>/<slug>; here that root
    # is the bundled storage tree.
    book_dir = bundle / "storage" / "books" / args.slug
    if not book_dir.is_dir():
        print(f"No book at {book_dir}", file=sys.stderr)
        return 2

    # Override the storage root so persist.book_dir() points at the bundle.
    persist.config.__dict__["storage_root"] = str(bundle / "storage" / "books")

    manifest = persist.read_manifest(args.slug)
    if not manifest:
        print(f"No manifest at {book_dir}/manifest.json", file=sys.stderr)
        return 2

    # Pre-flight: if a Writing already exists with this title for the
    # primary account, refuse (unless --force).
    engine = create_async_engine(settings.database_url, future=True)
    Session = async_sessionmaker(engine, expire_on_commit=False)
    async with Session() as db:
        from app.models.user import User  # noqa: E402
        existing_user = (
            await db.execute(select(User).where(User.email == args.account_email))
        ).scalar_one_or_none()
        if existing_user is not None and not args.force:
            existing_writing = (
                await db.execute(
                    select(Writing).where(
                        Writing.user_id == existing_user.id,
                        Writing.title == manifest["title"],
                    )
                )
            ).scalar_one_or_none()
            if existing_writing is not None:
                print(
                    f"Writing already exists: id={existing_writing.id} "
                    f"title={manifest['title']!r} owner={args.account_email}\n"
                    f"Pass --force to publish a fresh copy.",
                    file=sys.stderr,
                )
                return 1

    # Load artifacts from disk.
    chunks, briefs, deeps, scenes_by_chunk = _load_artifacts(args.slug)
    if not chunks:
        print("No chunks on disk — nothing to publish.", file=sys.stderr)
        return 2

    # Upload images to MinIO (or skip in --no-images mode). The cover (if
    # the poster phase produced one at images/cover.png) is uploaded as
    # a regular PNG; we just look for it by filename.
    cover_local_path: str | None = None
    book = persist.book_dir(args.slug)
    cover_png = book / "images" / "cover.png"
    if cover_png.exists():
        cover_local_path = str(cover_png)

    image_url_for_path: dict[str, str] = {}
    if args.no_images:
        image_url_for_path = {
            gs.image_path: Path(gs.image_path).resolve().as_uri()
            for pairs in scenes_by_chunk.values()
            for _, gs in pairs
        }
        if cover_local_path:
            image_url_for_path[cover_local_path] = Path(cover_local_path).resolve().as_uri()
    else:
        image_url_for_path = await _upload_images(args.slug, scenes_by_chunk, extra_files=[cover_local_path] if cover_local_path else [])

    def url_for(local_path: str) -> str:
        return image_url_for_path.get(local_path, Path(local_path).resolve().as_uri())

    # Cover priority: poster's dedicated cover.png > highest-scoring scene.
    if cover_local_path:
        cover_url = url_for(cover_local_path)
    else:
        scene_cover = _pick_cover(scenes_by_chunk)
        cover_url = url_for(scene_cover) if scene_cover else None

    poster = manifest.get("poster") or {}
    description = poster.get("description") or manifest.get("description")
    genres = poster.get("genres") or []
    writing_types = poster.get("writing_types") or []
    tags = poster.get("tags") or []

    # Pick up cleaner-phase output if it ran. Each chunk gets its
    # cleaned markdown loaded into a {chunk_id: md} dict so the delta
    # builder can paragraph it properly.
    cleaned_md: dict[str, str] = {}
    cleaned_dir = book / "cleaned"
    if cleaned_dir.is_dir():
        for p in cleaned_dir.glob("*.md"):
            try:
                text = p.read_text(encoding="utf-8")
                if text.strip():
                    cleaned_md[p.stem] = text
            except OSError:
                pass
    if cleaned_md:
        print(f"[clean] loaded {len(cleaned_md)} cleaned chunks from disk", file=sys.stderr)

    # Upload the avatar to MinIO if provided. We use a stable key per email
    # so re-runs overwrite rather than scatter copies.
    avatar_url: str | None = None
    if args.account_avatar:
        avatar_path = Path(args.account_avatar)
        if not avatar_path.is_absolute():
            avatar_path = (bundle / args.account_avatar).resolve()
        if not avatar_path.exists():
            print(f"Avatar not found: {avatar_path}", file=sys.stderr)
            return 2
        avatar_url = await _upload_avatar(args.account_email, avatar_path)
        print(f"[avatar] {avatar_url}", file=sys.stderr)

    db_ids = await db_publish.publish_book(
        title=manifest["title"],
        author=manifest.get("author"),
        description=description,
        cover_image_path=cover_url,
        chunks=chunks,
        briefs=briefs,
        deeps=deeps,
        scenes_by_chunk=scenes_by_chunk,
        image_url_for=url_for,
        primary_account_email=args.account_email,
        primary_account_name=args.account_name,
        primary_account_password=args.account_password,
        primary_account_avatar_url=avatar_url,
        genres=genres,
        writing_types=writing_types,
        tags=tags,
        cleaned_markdown=cleaned_md,
    )

    manifest.setdefault("synced_history", []).append(db_ids)
    manifest["synced"] = db_ids
    persist.write_manifest(args.slug, manifest)

    print(json.dumps({"slug": args.slug, "synced": db_ids}, indent=2))
    return 0


# ---- helpers (lifted from sync_to_db.py, local copies kept slim) ------

def _load_artifacts(slug):
    """Read every per-chunk JSON + per-image JSON. Returns
    (chunks, briefs, deeps, scenes_by_chunk)."""
    from book_ingest import persist
    from book_ingest.image_planner import PlannedScene
    from book_ingest.schemas import Chunk, ChunkBrief, ChunkDeep, GeneratedScene

    book = persist.book_dir(slug)
    chunks: list = []
    briefs: dict = {}
    deeps: dict = {}

    for path in sorted((book / "chunks").glob("*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        chunk = Chunk.model_validate(payload["chunk"])
        chunks.append(chunk)
        if payload.get("brief"):
            briefs[chunk.id] = ChunkBrief.model_validate(payload["brief"])
        deep_dict = payload.get("deep") or {}
        # Skip degraded fallback deeps where the reduce agent's LLM call
        # failed permanently — would otherwise surface in the reader as
        # "[reduce failed: …]" italicized at the top of the section.
        rich = (deep_dict.get("rich_summary") or "") if isinstance(deep_dict, dict) else ""
        if isinstance(deep_dict, dict) and deep_dict and not (
            rich.startswith("[reduce failed:") or rich.startswith("[map failed:")
        ):
            deeps[chunk.id] = ChunkDeep.model_validate(deep_dict)

    chunks.sort(key=lambda c: (c.page_start, c.page_end))

    plan_path = book / "plan.json"
    plan_by_scene = {}
    if plan_path.exists():
        for entry in json.loads(plan_path.read_text(encoding="utf-8")):
            plan_by_scene[entry["scene_id"]] = PlannedScene(
                scene_id=entry["scene_id"],
                chunk_id=entry["chunk_id"],
                chapter_title=entry.get("chapter_title"),
                scene_text=entry["scene_text"],
                score=float(entry.get("score", 0.0)),
            )

    scenes_by_chunk: dict = {}
    for meta_path in sorted((book / "images").glob("*.json")):
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        # Skip the cover — it's handled separately in _main().
        if meta.get("is_cover") or meta.get("chunk_id") is None:
            continue
        scene_id = meta["scene_id"]
        chunk_id = meta["chunk_id"]
        local_image = meta.get("image_path")
        if not local_image:
            continue
        # In-bundle path: rebase the recorded image_path onto the bundle's
        # books/<slug>/images/<scene_id>.png. The studio recorded an
        # absolute path on the dev machine; here we substitute the
        # in-container path.
        rebased = book / "images" / f"{scene_id}.png"
        if not rebased.exists():
            continue
        gs = GeneratedScene(
            scene_id=scene_id,
            chunk_id=chunk_id,
            prompt=meta.get("prompt", ""),
            image_path=str(rebased),
        )
        ps = plan_by_scene.get(scene_id) or PlannedScene(
            scene_id=scene_id,
            chunk_id=chunk_id,
            chapter_title=meta.get("chapter_title"),
            scene_text=meta.get("scene_text", ""),
            score=float(meta.get("score", 0.0)),
        )
        scenes_by_chunk.setdefault(chunk_id, []).append((ps, gs))

    for chunk_id in scenes_by_chunk:
        scenes_by_chunk[chunk_id].sort(key=lambda pair: pair[0].score, reverse=True)

    return chunks, briefs, deeps, scenes_by_chunk


def _pick_cover(scenes_by_chunk):
    best = None
    for pairs in scenes_by_chunk.values():
        for planned, scene in pairs:
            if best is None or planned.score > best[0]:
                best = (planned.score, scene.image_path)
    return best[1] if best else None


async def _upload_avatar(email: str, avatar_path: Path) -> str:
    """Upload the avatar to MinIO at users/<sanitized-email>/avatar.<ext> and
    return its public URL. Stable per-email key so re-runs replace, not pile."""
    from app.storage import upload_file  # type: ignore[import-not-found]
    import re

    safe = re.sub(r"[^a-zA-Z0-9._-]+", "_", email.lower())
    ext = avatar_path.suffix.lstrip(".") or "png"
    content_type = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                    "webp": "image/webp"}.get(ext.lower(), "application/octet-stream")
    with open(avatar_path, "rb") as fh:
        data = fh.read()
    return await upload_file(f"users/{safe}/avatar.{ext}", data, content_type=content_type)


async def _upload_images(slug, scenes_by_chunk, *, extra_files=None):
    """Upload every PNG to MinIO under books/<slug>/<scene_id>.png. Also
    uploads any extra_files (e.g. the cover.png) using their filename
    stem as the object key."""
    from app.storage import upload_file  # type: ignore[import-not-found]

    out: dict = {}

    async def _put(local_path, scene_id):
        with open(local_path, "rb") as fh:
            data = fh.read()
        url = await upload_file(
            f"books/{slug}/{scene_id}.png",
            data,
            content_type="image/png",
        )
        out[local_path] = url

    tasks = []
    for pairs in scenes_by_chunk.values():
        for _, gs in pairs:
            tasks.append(asyncio.create_task(_put(gs.image_path, gs.scene_id)))
    for extra in (extra_files or []):
        if not extra:
            continue
        sid = Path(extra).stem
        tasks.append(asyncio.create_task(_put(extra, sid)))
    if tasks:
        await asyncio.gather(*tasks)
    print(f"[minio] uploaded {len(out)} images", file=sys.stderr)
    return out


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
