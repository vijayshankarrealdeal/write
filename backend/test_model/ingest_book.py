"""CLI entrypoint for the book-ingest pipeline.

Single-file end-to-end usage (default):

    python ingest_book.py /data/bible.pdf
    python ingest_book.py "data/gutenberg-selected/00084_Frankenstein_ or_ the modern prometheus.html"

Accepts PDF (`.pdf`) and Project Gutenberg HTML (`.html`/`.htm`) the same
way — one command runs the LLM/image pipeline AND uploads the result to
Postgres + MinIO under the canonical `inkspace@inkspacex.com` account
(public, published, immediately live in the app). Re-runs are idempotent:
the writing's `synced` marker on the manifest short-circuits a second
DB write.

Pass `--no-sync` to do filesystem-only output (the old behavior). After
that, `python sync_to_db.py <slug>` performs the DB upload separately —
useful when you want to eyeball the local artifacts before pushing.

For HTML, title/author are auto-filled from `<meta>` tags inside the
file; override with `--title`/`--author`. The Gutenberg digit prefix
(`00084_`) is stripped from the slug.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

# Ensure the backend root is on sys.path so `from app.*` works when this
# script runs as a standalone file from `backend/test_model/`.
_HERE = Path(__file__).resolve().parent
_BACKEND_ROOT = _HERE.parent
if str(_BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(_BACKEND_ROOT))

from book_ingest.pipeline import ingest_pdf  # noqa: E402


def _title_from_filename(pdf: Path) -> str:
    import re
    stem = re.sub(r"^\d+_", "", pdf.stem)  # strip Gutenberg "00084_" prefix
    stem = stem.replace("_", " ").replace("-", " ").strip()
    return stem.title() if stem else pdf.name


def _slug_from_filename(pdf: Path) -> str:
    """Folder name = sanitized filename stem so the output folder mirrors
    the source the user dropped in. Gutenberg's leading digit prefix
    (`00084_`) is dropped so `frankenstein-...` is the slug, not
    `00084-frankenstein-...`."""
    import re
    stem = re.sub(r"^\d+_", "", pdf.stem)
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", stem.lower()).strip("-")
    return slug or "book"


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Ingest a book PDF or Gutenberg HTML.")
    p.add_argument("pdf", help="Path to the PDF or HTML file.")
    p.add_argument("--title", default=None,
                   help="Override the book title (default: derived from filename).")
    p.add_argument("--author", default=None)
    p.add_argument("--description", default=None)
    p.add_argument("--image-budget", type=int, default=None)
    p.add_argument("--style", default="editorial illustration, muted palette")
    p.add_argument("--reader-preference", default=None,
                   help="What the reader cares about — steers highlight + image picks.")
    p.add_argument("--no-sync", action="store_true",
                   help="Skip the Postgres+MinIO upload; produce filesystem "
                        "artifacts only (the old behavior).")
    p.add_argument("--force", action="store_true",
                   help="Re-publish even if the manifest already records a sync.")
    return p.parse_args()


async def _main() -> int:
    args = _parse_args()
    pdf_path = Path(args.pdf)
    if not pdf_path.exists():
        print(f"PDF not found: {pdf_path}", file=sys.stderr)
        return 2

    # For HTML, prefer Gutenberg's <meta dc.title> over the filename
    # guess — the loader extracts it. Pass title=None so the pipeline
    # picks loader_title; only fall back to filename for PDFs.
    is_html = pdf_path.suffix.lower() in (".html", ".htm")
    if args.title:
        title = args.title  # explicit override always wins
    elif is_html:
        title = None  # let html_loader fill it in
    else:
        title = _title_from_filename(pdf_path)
    slug = _slug_from_filename(pdf_path)

    result = await ingest_pdf(
        pdf_path=str(pdf_path),
        title=title,
        slug=slug,
        author=args.author,
        description=args.description,
        image_budget=args.image_budget,
        style=args.style,
        reader_preference=args.reader_preference,
    )

    sync_payload: dict | None = None
    if not args.no_sync:
        # End-to-end mode: push to Postgres + MinIO as the inkspace user
        # immediately. Same code path as `python sync_to_db.py <slug>`,
        # invoked here so a single command takes a fresh PDF/HTML all the
        # way to "live in the app" without a manual second step.
        sync_payload = await _sync_now(result.slug, force=args.force)

    print()
    print(json.dumps({
        "slug": result.slug,
        "book_dir": result.book_dir,
        "pages": result.n_pages,
        "chunks": result.n_chunks,
        "deep_summaries": result.n_deep,
        "images": result.n_images,
        "chunk_embeddings": result.n_chunk_embeddings,
        "scene_embeddings": result.n_scene_embeddings,
        "synced": sync_payload,
        "next_steps": (
            ["live in the app — log in as inkspace@inkspacex.com / Google@99 to verify"]
            if sync_payload
            else [f"python sync_to_db.py {result.slug}"]
        ),
    }, indent=2, default=str))
    return 0


async def _sync_now(slug: str, *, force: bool) -> dict | None:
    """Run the same DB+MinIO upload `sync_to_db.py` does, in-process.

    Returns the manifest's `synced` block (or None if the book was already
    synced and `force` wasn't passed). Raises on hard failures so the
    caller can surface them — partial-success isn't a useful state for a
    single-file CLI.
    """
    # Lazy imports: keep the module import-clean for `--no-sync` callers
    # who haven't configured Postgres/MinIO locally.
    from book_ingest import db_publish, persist
    from sync_to_db import (
        _build_cleaned_markdown_map,
        _load_artifacts,
        _pick_cover,
        _upload_images,
    )

    manifest = persist.read_manifest(slug)
    if manifest is None:
        raise RuntimeError(f"manifest missing for slug={slug} after ingest")
    if manifest.get("synced") and not force:
        print(f"[sync] {slug}: already synced — pass --force to republish.")
        return manifest["synced"]

    chunks, briefs, deeps, scenes_by_chunk_local = _load_artifacts(slug)
    if not chunks:
        raise RuntimeError("no chunks on disk after ingest — pipeline bug?")

    image_url_for_path = await _upload_images(slug, scenes_by_chunk_local)

    def url_for(local_path: str) -> str:
        return image_url_for_path.get(local_path, Path(local_path).resolve().as_uri())

    cover_local = manifest.get("cover_image_local") or _pick_cover(scenes_by_chunk_local)
    cover_url: str | None = None
    if cover_local and Path(cover_local).exists():
        from app.storage import upload_file  # type: ignore[import-not-found]
        with open(cover_local, "rb") as fh:
            cover_data = fh.read()
        cover_url = await upload_file(
            f"books/{slug}/cover.png",
            cover_data,
            content_type="image/png",
        )

    cleaned_md_map = _build_cleaned_markdown_map(slug, chunks)
    poster = manifest.get("poster") or {}
    description = (
        manifest.get("description")
        or poster.get("back_cover_copy")
        or manifest.get("subtitle")
    )

    db_ids = await db_publish.publish_book(
        title=manifest["title"],
        author=manifest.get("author"),
        description=description,
        cover_image_path=cover_url,
        chunks=chunks,
        briefs=briefs,
        deeps=deeps,
        scenes_by_chunk=scenes_by_chunk_local,
        image_url_for=url_for,
        cleaned_markdown=cleaned_md_map,
        primary_account_email=db_publish.INKSPACE_EMAIL,
        primary_account_name=db_publish.INKSPACE_NAME,
        primary_account_password=db_publish.INKSPACE_PASSWORD,
        genres=poster.get("genres") or [],
        writing_types=poster.get("writing_types") or ["book"],
        tags=poster.get("tags") or [],
        visibility="public",
    )
    manifest["synced"] = db_ids
    persist.write_manifest(slug, manifest)
    return db_ids


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
