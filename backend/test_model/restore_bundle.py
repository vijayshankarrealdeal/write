"""Replay a previously-ingested book from its `<slug>.zip` bundle.

The bundle is the offline replay format. After `ingest_book.py` finishes,
it writes `storage/books/<slug>/<slug>.zip` containing every artifact
needed to publish the book — manifest, chunks (with cleaned markdown +
briefs + deeps), plan, highlights, every PNG with prompt metadata, and
embeddings. No raw PDF/HTML, no re-running of LLM or image gen.

Use this when:
  • Postgres or MinIO has been wiped and you need to recreate a book.
  • Migrating to a new infra (different bucket, different DB host) —
    point your `.env` at the new env, run `restore_bundle.py … --sync`.
  • Sharing a book between machines without re-paying for LLM/image work.

Usage:

    # Just unpack the bundle into storage/books/<slug>/, no DB sync.
    python restore_bundle.py storage/books/frankenstein/frankenstein.zip

    # Unpack AND sync to MinIO + Postgres (equivalent to running
    # sync_to_db.py afterwards).
    python restore_bundle.py storage/books/frankenstein/frankenstein.zip --sync

    # Restore into a different slug (e.g. for an A/B publish).
    python restore_bundle.py frankenstein.zip --slug frankenstein-rerelease

    # Inspect a bundle without unpacking it.
    python restore_bundle.py frankenstein.zip --info

The restore is idempotent: extracting a bundle on top of an existing
folder overwrites the artifacts with the bundled copies. The
`--sync` step is itself idempotent (sync_to_db.py refuses to publish
a second copy unless `--force` is passed).
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

from book_ingest import bundler, persist  # noqa: E402


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Restore a book from its replay bundle "
                    "(unpacks + optionally syncs to DB/MinIO)."
    )
    p.add_argument("zip_path", help="Path to <slug>.zip produced by ingest_book.py")
    p.add_argument("--slug", default=None,
                   help="Restore under a different slug than the one stored in "
                        "bundle.json (useful for A/B re-publishes).")
    p.add_argument("--sync", action="store_true",
                   help="After restoring, run the sync_to_db flow (uploads "
                        "images to MinIO, creates Writing/Section/FeedItem rows).")
    p.add_argument("--force-sync", action="store_true",
                   help="Pass --force to sync_to_db so it republishes even if "
                        "the bundled manifest already shows synced IDs.")
    p.add_argument("--info", action="store_true",
                   help="Just print bundle metadata; don't extract anything.")
    return p.parse_args()


async def _main() -> int:
    args = _parse_args()
    zip_path = Path(args.zip_path).resolve()
    if not zip_path.exists():
        print(f"Bundle not found: {zip_path}", file=sys.stderr)
        return 2

    try:
        meta = bundler.read_bundle_meta(zip_path)
    except (KeyError, ValueError, OSError) as exc:
        print(f"Not a valid bundle: {zip_path} ({exc})", file=sys.stderr)
        return 2

    if args.info:
        print(json.dumps(meta, indent=2, ensure_ascii=False))
        return 0

    target_slug = args.slug or meta["slug"]
    dest = persist.book_dir(target_slug)  # creates storage/books/<slug>/ tree
    print(f"[restore] {zip_path}")
    print(f"          → {dest}")
    print(f"          slug:   {target_slug}"
          + (f"  (was {meta['slug']!r} in bundle)" if args.slug else ""))
    print(f"          title:  {meta.get('title') or '(unknown)'}")
    print(f"          author: {meta.get('author') or '(unknown)'}")
    print(f"          format: v{meta.get('format_version')}, "
          f"{meta.get('file_count')} files, "
          f"created {meta.get('created_utc')}")

    bundler.extract_bundle(zip_path, dest)

    # If we restored under a renamed slug, fix up the manifest so
    # downstream tools (sync_to_db, regenerate_image) refer to the new
    # name consistently.
    if args.slug and args.slug != meta["slug"]:
        manifest = persist.read_manifest(target_slug)
        if manifest:
            manifest["slug"] = target_slug
            # Drop synced IDs that referred to a previous publish — the
            # operator asked for a fresh slug, so a fresh publish should
            # go through.
            manifest.pop("synced", None)
            persist.write_manifest(target_slug, manifest)

    print(f"[restore] extracted {meta.get('file_count')} files.")

    if not args.sync:
        print()
        print("Next: python sync_to_db.py "
              + (f"{target_slug}" if " " not in target_slug else f'"{target_slug}"'))
        return 0

    # Delegate to sync_to_db's main flow programmatically. Re-import here
    # so a `--info` run never imports the heavy app.* stack.
    print(f"[sync] uploading images + creating DB rows for {target_slug}…")
    from sync_to_db import (
        _build_cleaned_markdown_map,
        _load_artifacts,
        _pick_cover,
        _upload_images,
    )  # noqa: E402

    chunks, briefs, deeps, scenes_by_chunk = _load_artifacts(target_slug)
    if not chunks:
        print("No chunks restored — bundle may be incomplete.", file=sys.stderr)
        return 2

    image_url_for_path = await _upload_images(target_slug, scenes_by_chunk)

    def url_for(local_path: str) -> str:
        return image_url_for_path.get(local_path, Path(local_path).resolve().as_uri())

    from book_ingest import db_publish  # lazy: imports app.*

    manifest = persist.read_manifest(target_slug)
    if manifest.get("synced") and not args.force_sync:
        print(f"[sync] manifest already shows synced ids: "
              f"{manifest['synced']}.\nPass --force-sync to publish a fresh copy.")
        return 0

    cover_local = manifest.get("cover_image_local") or _pick_cover(scenes_by_chunk)
    cover_url: str | None = None
    if cover_local and Path(cover_local).exists():
        from app.storage import upload_file  # type: ignore[import-not-found]
        with open(cover_local, "rb") as fh:
            cover_data = fh.read()
        cover_url = await upload_file(
            f"books/{target_slug}/cover.png",
            cover_data,
            content_type="image/png",
        )

    cleaned_md_map = _build_cleaned_markdown_map(target_slug, chunks)
    poster = manifest.get("poster") or {}

    db_ids = await db_publish.publish_book(
        title=manifest["title"],
        author=manifest.get("author"),
        description=manifest.get("description") or poster.get("back_cover_copy"),
        cover_image_path=cover_url,
        chunks=chunks,
        briefs=briefs,
        deeps=deeps,
        scenes_by_chunk=scenes_by_chunk,
        image_url_for=url_for,
        cleaned_markdown=cleaned_md_map,
        primary_account_email="inkspacex@inkspacex.com",
        primary_account_name="inkspace",
        genres=poster.get("genres") or [],
        writing_types=poster.get("writing_types") or ["book"],
        tags=poster.get("tags") or [],
    )
    manifest["synced"] = db_ids
    persist.write_manifest(target_slug, manifest)
    print(json.dumps({"slug": target_slug, "synced": db_ids}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
