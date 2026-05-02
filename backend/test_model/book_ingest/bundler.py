"""Phase 7 — pack a finished book into a single replay zip.

The bundle holds everything `sync_to_db.py` needs to publish a book:

  manifest.json           title, author, scout, poster, style, slug, …
  chunks/<id>.json        chunk text + brief + deep + scene_ids
  plan.json               scene plan with scores
  highlights.json         flat list of highlight spans
  embeddings/*.json       chunk + scene vectors (skipped on restore-only;
                          re-embedded cheaply if the operator needs them)
  images/<scene>.png      every illustration
  images/<scene>.json     per-scene prompt + scene_text + score
  cover.png               (optional) the poster cover image
  bundle.json             metadata about the bundle itself (version,
                          timestamps, file inventory, source slug)

What we deliberately *don't* include:

  pages/*.json     — raw PDF page text. Large, regenerable from source.
  briefs/*.json    — superseded by chunks/*.json (which embeds the brief).
  deeps/*.json     — superseded by chunks/*.json.
  cleaned/*.md     — superseded by chunks/*.json (PDF path only anyway).
  _preview/        — debug artifacts from preview_html.py.

Replay flow (see `restore_bundle.py`):

  1. Unzip into `storage/books/<slug>/` — this puts every artifact back
     where the rest of the pipeline expects it.
  2. Run `python sync_to_db.py <slug>` — uploads images to MinIO and
     creates Writing/Section/FeedItem rows. Same code path as a fresh
     ingest, just driven by the artifacts already on disk.

Resilience: the bundle is written via a temp file + atomic rename, so
a power cut during bundling never leaves a half-zip behind.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import persist


BUNDLE_FORMAT_VERSION = 1


def bundle_path(slug: str) -> Path:
    """Where the bundle lives on disk: alongside the rest of the artifacts.
    Discoverable via `glob('storage/books/*/<slug>.zip')`."""
    return persist.book_dir(slug) / f"{slug}.zip"


def write_bundle(slug: str) -> tuple[Path, dict[str, Any]]:
    """Create (or refresh) the bundle for `slug`. Returns the path and an
    info dict (size, sha256, file_count, contents) suitable for stashing
    in `manifest.bundle`."""
    book = persist.book_dir(slug)
    out = bundle_path(slug)

    # File inventory: (arcname, abs_path). arcname is the path *inside* the
    # zip — we keep the same layout the pipeline writes on disk so restore
    # is just `unzip into storage/books/<slug>/`.
    members: list[tuple[str, Path]] = []

    def _add(arcname: str, path: Path) -> None:
        if path.exists() and path.is_file():
            members.append((arcname, path))

    # Top-level manifest + plan + highlights.
    _add("manifest.json", book / "manifest.json")
    _add("plan.json", book / "plan.json")
    _add("highlights.json", book / "highlights.json")

    # Composite chunk records (text + brief + deep + scene_ids).
    for p in sorted((book / "chunks").glob("*.json")):
        _add(f"chunks/{p.name}", p)

    # Images + per-scene meta.
    images_dir = book / "images"
    if images_dir.exists():
        for p in sorted(images_dir.iterdir()):
            if p.suffix.lower() in (".png", ".json") and p.is_file():
                _add(f"images/{p.name}", p)

    # Embeddings — small JSON arrays. Cheap to keep, saves a re-embed
    # pass on restore if the user wants regenerate_image.py to work
    # against the restored book without paying for embeddings again.
    emb_dir = book / "embeddings"
    if emb_dir.exists():
        for p in sorted(emb_dir.glob("*.json")):
            _add(f"embeddings/{p.name}", p)

    # Cover image (the poster phase may have written one outside images/).
    manifest = persist.read_manifest(slug)
    cover_local = manifest.get("cover_image_local") if manifest else None
    if cover_local:
        cover_path = Path(cover_local)
        if cover_path.exists() and cover_path.is_file():
            # Always store the cover under a stable name so restore can
            # find it even if the original lived outside book_dir.
            _add(f"cover{cover_path.suffix.lower() or '.png'}", cover_path)

    if not members:
        raise RuntimeError(f"Nothing to bundle for slug={slug!r} — book_dir empty?")

    # Bundle metadata — written into the zip itself so the restore script
    # can sanity-check the archive without unzipping it first.
    bundle_meta = {
        "format_version": BUNDLE_FORMAT_VERSION,
        "slug": slug,
        "title": (manifest or {}).get("title"),
        "author": (manifest or {}).get("author"),
        "source_format": (manifest or {}).get("source_format"),
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "file_count": len(members),
        "files": [arc for arc, _ in members],
    }

    # Atomic write: build into <out>.tmp, then rename. Survives Ctrl-C.
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_name = tempfile.mkstemp(
        prefix=out.name + ".",
        suffix=".tmp",
        dir=str(out.parent),
    )
    os.close(tmp_fd)
    tmp_path = Path(tmp_name)
    try:
        with zipfile.ZipFile(
            tmp_path,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=6,
            allowZip64=True,
        ) as zf:
            zf.writestr(
                "bundle.json",
                json.dumps(bundle_meta, indent=2, ensure_ascii=False),
            )
            for arcname, src in members:
                zf.write(src, arcname=arcname)
        os.replace(tmp_path, out)
    except Exception:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
        raise

    size_bytes = out.stat().st_size
    sha = _sha256(out)

    info = {
        "path": str(out),
        "size_bytes": size_bytes,
        "sha256": sha,
        "file_count": len(members) + 1,  # +1 for bundle.json
        "format_version": BUNDLE_FORMAT_VERSION,
        "created_utc": bundle_meta["created_utc"],
    }
    return out, info


def read_bundle_meta(zip_path: Path) -> dict[str, Any]:
    """Return the `bundle.json` from inside the zip without extracting it."""
    with zipfile.ZipFile(zip_path, mode="r") as zf:
        with zf.open("bundle.json") as fh:
            return json.loads(fh.read().decode("utf-8"))


def extract_bundle(zip_path: Path, dest_book_dir: Path) -> dict[str, Any]:
    """Unzip a bundle into `dest_book_dir` (the per-slug folder under
    storage/books/). Returns the bundle.json metadata. Existing files are
    overwritten — this is intentional: restore is meant to put the book
    in a known-good state. Refuses to extract paths containing `..` to
    block zip-slip attacks."""
    dest_book_dir.mkdir(parents=True, exist_ok=True)
    meta: dict[str, Any] | None = None
    with zipfile.ZipFile(zip_path, mode="r") as zf:
        # Validate every member path *before* writing anything.
        for name in zf.namelist():
            normalized = os.path.normpath(name)
            if normalized.startswith("..") or os.path.isabs(normalized):
                raise ValueError(
                    f"Refusing to extract suspicious path from bundle: {name!r}"
                )
        for name in zf.namelist():
            if name == "bundle.json":
                with zf.open(name) as fh:
                    meta = json.loads(fh.read().decode("utf-8"))
                continue
            target = dest_book_dir / name
            if name.endswith("/"):
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(name) as src, open(target, "wb") as dst:
                dst.write(src.read())
    if meta is None:
        raise ValueError(f"No bundle.json inside {zip_path} — not a valid bundle.")
    return meta


def _sha256(path: Path, *, chunk_size: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            buf = fh.read(chunk_size)
            if not buf:
                break
            h.update(buf)
    return h.hexdigest()
