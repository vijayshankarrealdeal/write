"""CLI entrypoint for the book-ingest pipeline.

Usage (single-arg form — recommended):

    python ingest_book.py /data/bible.pdf

The output folder is named after the PDF filename (`bible.pdf` →
`storage/books/bible/`) and contains every JSON + image the pipeline
produces. Database + MinIO sync is a *separate, manual* step:

    python sync_to_db.py bible

Optional flags exist for tuning (image budget, style, reader preference,
explicit title/author override) but the bare PDF path is enough.
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
    stem = pdf.stem.replace("_", " ").replace("-", " ").strip()
    return stem.title() if stem else pdf.name


def _slug_from_filename(pdf: Path) -> str:
    """Folder name = sanitized filename stem so the output folder mirrors
    the PDF the user dropped in."""
    import re
    stem = pdf.stem
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", stem.lower()).strip("-")
    return slug or "book"


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Ingest a book PDF.")
    p.add_argument("pdf", help="Path to the PDF file.")
    p.add_argument("--title", default=None,
                   help="Override the book title (default: derived from filename).")
    p.add_argument("--author", default=None)
    p.add_argument("--description", default=None)
    p.add_argument("--image-budget", type=int, default=None)
    p.add_argument("--style", default="editorial illustration, muted palette")
    p.add_argument("--reader-preference", default=None,
                   help="What the reader cares about — steers highlight + image picks.")
    return p.parse_args()


async def _main() -> int:
    args = _parse_args()
    pdf_path = Path(args.pdf)
    if not pdf_path.exists():
        print(f"PDF not found: {pdf_path}", file=sys.stderr)
        return 2

    title = args.title or _title_from_filename(pdf_path)
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
        "next_steps": [
            f"python sync_to_db.py {result.slug}",
            f"python regenerate_image.py {result.slug} --query \"...\" --instruction \"...\"",
        ],
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
