"""Preview the Gutenberg HTML loader output for one book.

This is the "upload button" — point it at one HTML file from
`data/gutenberg-selected/` and it runs *only* the loader phase. Nothing
hits an LLM, an image API, MinIO, or Postgres. The loader's output is
written to `storage/books/<slug>/_preview/` so you can eyeball whether
the front-matter stripping, chapter splitting, and HTML→markdown
conversion look right before we run the full pipeline (which costs $).

Usage:

    python preview_html.py "data/gutenberg-selected/00084_Frankenstein_ or_ the modern prometheus.html"

Output:
  storage/books/<slug>/_preview/
    metadata.json     — title, author, subjects, page count, chapter list
    chapter_001.md    — first chapter (or letter), one file per chapter
    chapter_002.md    — second
    …
    full.md           — every chapter concatenated, the way the chunker
                        will see it
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_BACKEND_ROOT = _HERE.parent
if str(_BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(_BACKEND_ROOT))

from book_ingest.html_loader import load_html  # noqa: E402


def _slug_from_filename(path: Path) -> str:
    stem = path.stem
    # Strip leading "00084_" Gutenberg id prefix if present.
    stem = re.sub(r"^\d+_", "", stem)
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", stem.lower()).strip("-")
    return slug or "book"


def _title_from_filename(path: Path) -> str:
    stem = path.stem
    stem = re.sub(r"^\d+_", "", stem)
    return stem.replace("_", " ").replace("-", " ").strip()


def main() -> int:
    p = argparse.ArgumentParser(description="Preview the Gutenberg HTML loader output.")
    p.add_argument("html", help="Path to a Gutenberg HTML file.")
    p.add_argument("--slug", default=None, help="Override output folder name.")
    p.add_argument("--max-chapters", type=int, default=None,
                   help="Only emit the first N chapters to disk (still counts the rest).")
    args = p.parse_args()

    html_path = Path(args.html)
    if not html_path.exists():
        print(f"HTML not found: {html_path}", file=sys.stderr)
        return 2

    slug = args.slug or _slug_from_filename(html_path)
    title_from_file = _title_from_filename(html_path)

    print(f"[load] {html_path.name}")
    loaded = load_html(str(html_path))

    out_dir = _HERE / "storage" / "books" / slug / "_preview"
    out_dir.mkdir(parents=True, exist_ok=True)

    # Wipe any stale chapter files from a prior run so a shorter book
    # doesn't leave behind chapter_099.md from a previous longer one.
    for stale in out_dir.glob("chapter_*.md"):
        stale.unlink()

    chapters_written = 0
    full_parts: list[str] = []
    for page in loaded.pages:
        full_parts.append(page.text)
        if args.max_chapters is None or chapters_written < args.max_chapters:
            chapter_path = out_dir / f"chapter_{page.no:03d}.md"
            chapter_path.write_text(page.text, encoding="utf-8")
            chapters_written += 1

    (out_dir / "full.md").write_text("\n\n".join(full_parts), encoding="utf-8")

    metadata = {
        "source_file": str(html_path),
        "slug": slug,
        "title_from_meta": loaded.title,
        "title_from_filename": title_from_file,
        "author": loaded.author,
        "subjects": loaded.subjects,
        "n_chapters": len(loaded.pages),
        "total_chars": sum(p.char_count for p in loaded.pages),
        "toc": [
            {"level": e.level, "title": e.title, "page": e.page}
            for e in loaded.toc
        ],
        "chapters": [
            {"page": p.no, "char_count": p.char_count,
             "first_line": (p.text.splitlines()[0] if p.text.splitlines() else "")[:120]}
            for p in loaded.pages
        ],
    }
    (out_dir / "metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    print()
    print(f"  title:    {loaded.title or '(none)'}")
    print(f"  author:   {loaded.author or '(none)'}")
    print(f"  subjects: {', '.join(loaded.subjects or []) or '(none)'}")
    print(f"  chapters: {len(loaded.pages)}")
    print(f"  chars:    {sum(p.char_count for p in loaded.pages):,}")
    print(f"  output:   {out_dir}")
    print()
    print("First 8 chapters detected:")
    for p in loaded.pages[:8]:
        first_line = next((ln for ln in p.text.splitlines() if ln.strip()), "")
        print(f"  {p.no:>3}.  [{p.char_count:>7,} ch]  {first_line[:80]}")
    if len(loaded.pages) > 8:
        print(f"  …  (+{len(loaded.pages) - 8} more)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
