"""Disk persistence — every artifact under `storage/books/<slug>/`.

Two design rules that matter for resilience:

1. **Per-item, not per-phase, files.** A 600-chunk map pass writes 600
   `briefs/<chunk_id>.json` files as each chunk completes. A power cut at
   chunk 347 keeps the 346 already on disk; resume only re-runs the 254
   that are missing.

2. **Atomic writes.** Every JSON write goes through `_atomic_write` —
   `<file>.tmp` first, then `os.replace` to the final name. POSIX
   guarantees the rename is atomic, so a power cut never leaves a
   half-written JSON file that would fail to parse on resume.
"""

from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any

from .config import config
from .image_planner import PlannedScene
from .schemas import Chunk, ChunkBrief, ChunkDeep, GeneratedScene, Page


# -----------------------------------------------------------------------
# Atomic IO
# -----------------------------------------------------------------------

def _atomic_write_text(path: Path, text: str) -> None:
    """Write `text` to `path` atomically. Survives power cut: either the
    old file or the new file is on disk after the syscall returns,
    never a half-written one."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_name = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=str(path.parent),
    )
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise


def _safe_read_json(path: Path) -> Any | None:
    """Read JSON; treat missing or corrupt files as 'not present' so resume
    just re-does the affected item rather than crashing."""
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


# -----------------------------------------------------------------------
# Slug + directory layout
# -----------------------------------------------------------------------

def slugify(name: str) -> str:
    s = re.sub(r"[^a-zA-Z0-9]+", "-", name.strip().lower()).strip("-")
    return s or "book"


def book_dir(slug: str) -> Path:
    p = Path(config.storage_root) / slug
    for sub in ("pages", "chunks", "briefs", "deeps", "images", "embeddings"):
        (p / sub).mkdir(parents=True, exist_ok=True)
    return p


# -----------------------------------------------------------------------
# Manifest
# -----------------------------------------------------------------------

def read_manifest(slug: str) -> dict[str, Any]:
    return _safe_read_json(book_dir(slug) / "manifest.json") or {}


def write_manifest(slug: str, manifest: dict[str, Any]) -> None:
    _atomic_write_text(
        book_dir(slug) / "manifest.json",
        json.dumps(manifest, indent=2),
    )


# -----------------------------------------------------------------------
# Pages
# -----------------------------------------------------------------------

def write_pages(slug: str, pages: list[Page]) -> None:
    root = book_dir(slug) / "pages"
    for p in pages:
        _atomic_write_text(root / f"{p.no:04d}.json", p.model_dump_json(indent=2))


# -----------------------------------------------------------------------
# Per-chunk briefs (map pass output, one file per chunk)
# -----------------------------------------------------------------------

def brief_path(slug: str, chunk_id: str) -> Path:
    return book_dir(slug) / "briefs" / f"{chunk_id}.json"


def write_brief(slug: str, chunk_id: str, brief: ChunkBrief) -> None:
    _atomic_write_text(brief_path(slug, chunk_id), brief.model_dump_json(indent=2))


def _is_failed_brief(b: ChunkBrief) -> bool:
    """A brief marked '[map failed: ...]' was the degraded fallback when
    the LLM call hit a transient error before retry classification was
    fixed. Treat it as missing so the next run gets a real shot."""
    return b.summary_1line.startswith("[map failed:")


def read_brief(slug: str, chunk_id: str, *, include_failed: bool = False) -> ChunkBrief | None:
    raw = _safe_read_json(brief_path(slug, chunk_id))
    if raw is None:
        return None
    try:
        b = ChunkBrief.model_validate(raw)
    except Exception:
        return None
    if not include_failed and _is_failed_brief(b):
        return None
    return b


def read_all_briefs(slug: str, *, include_failed: bool = False) -> dict[str, ChunkBrief]:
    out: dict[str, ChunkBrief] = {}
    for path in (book_dir(slug) / "briefs").glob("*.json"):
        chunk_id = path.stem
        b = read_brief(slug, chunk_id, include_failed=include_failed)
        if b is not None:
            out[chunk_id] = b
    return out


# -----------------------------------------------------------------------
# Per-chunk deeps (reduce pass output, one file per chunk)
# -----------------------------------------------------------------------

def deep_path(slug: str, chunk_id: str) -> Path:
    return book_dir(slug) / "deeps" / f"{chunk_id}.json"


def write_deep(slug: str, chunk_id: str, deep: ChunkDeep) -> None:
    _atomic_write_text(deep_path(slug, chunk_id), deep.model_dump_json(indent=2))


def _is_failed_deep(d: ChunkDeep) -> bool:
    return d.rich_summary.startswith("[reduce failed:")


def read_deep(slug: str, chunk_id: str, *, include_failed: bool = False) -> ChunkDeep | None:
    raw = _safe_read_json(deep_path(slug, chunk_id))
    if raw is None:
        return None
    try:
        d = ChunkDeep.model_validate(raw)
    except Exception:
        return None
    if not include_failed and _is_failed_deep(d):
        return None
    return d


def read_all_deeps(slug: str, *, include_failed: bool = False) -> dict[str, ChunkDeep]:
    out: dict[str, ChunkDeep] = {}
    for path in (book_dir(slug) / "deeps").glob("*.json"):
        chunk_id = path.stem
        d = read_deep(slug, chunk_id, include_failed=include_failed)
        if d is not None:
            out[chunk_id] = d
    return out


# -----------------------------------------------------------------------
# Composite chunk record (final, written once briefs+deeps are settled)
# -----------------------------------------------------------------------

def write_chunk(
    slug: str,
    chunk: Chunk,
    brief: ChunkBrief | None = None,
    deep: ChunkDeep | None = None,
    scene_ids: list[str] | None = None,
) -> None:
    payload = {
        "chunk": chunk.model_dump(),
        "brief": brief.model_dump() if brief else None,
        "deep": deep.model_dump() if deep else None,
        "scene_ids": scene_ids or [],
    }
    _atomic_write_text(
        book_dir(slug) / "chunks" / f"{chunk.id}.json",
        json.dumps(payload, indent=2),
    )


# -----------------------------------------------------------------------
# Images / scenes
# -----------------------------------------------------------------------

def image_path_for(slug: str, scene_id: str) -> Path:
    return book_dir(slug) / "images" / f"{scene_id}.png"


def scene_meta_path(slug: str, scene_id: str) -> Path:
    return book_dir(slug) / "images" / f"{scene_id}.json"


def write_scene_meta(
    slug: str,
    scene: GeneratedScene,
    planned: PlannedScene,
    *,
    extra: dict[str, Any] | None = None,
) -> None:
    meta = {
        "scene_id": scene.scene_id,
        "chunk_id": scene.chunk_id,
        "chapter_title": planned.chapter_title,
        "score": planned.score,
        "prompt": scene.prompt,
        "scene_text": planned.scene_text,
        "image_path": scene.image_path,
        "model": config.image_deployment,
    }
    if extra:
        meta.update(extra)
    _atomic_write_text(scene_meta_path(slug, scene.scene_id), json.dumps(meta, indent=2))


def read_scene_meta(slug: str, scene_id: str) -> dict[str, Any] | None:
    return _safe_read_json(scene_meta_path(slug, scene_id))


# -----------------------------------------------------------------------
# Highlights flat list
# -----------------------------------------------------------------------

def write_highlights(slug: str, deeps: dict[str, ChunkDeep]) -> None:
    flat: list[dict[str, Any]] = []
    for chunk_id, deep in deeps.items():
        for span in deep.highlight_spans:
            flat.append({
                "chunk_id": chunk_id,
                "start": span.start,
                "length": span.length,
                "color_hex": span.color_hex,
                "why": span.why,
            })
    _atomic_write_text(book_dir(slug) / "highlights.json", json.dumps(flat, indent=2))


# -----------------------------------------------------------------------
# Embeddings (one .json per chunk / scene; vectors are arrays of floats)
# -----------------------------------------------------------------------

def chunk_embedding_path(slug: str, chunk_id: str) -> Path:
    return book_dir(slug) / "embeddings" / f"chunk-{chunk_id}.json"


def scene_embedding_path(slug: str, scene_id: str) -> Path:
    return book_dir(slug) / "embeddings" / f"scene-{scene_id}.json"


def write_chunk_embedding(slug: str, chunk_id: str, text: str, vector: list[float]) -> None:
    _atomic_write_text(
        chunk_embedding_path(slug, chunk_id),
        json.dumps({"chunk_id": chunk_id, "text": text, "vector": vector}),
    )


def write_scene_embedding(slug: str, scene_id: str, text: str, vector: list[float]) -> None:
    _atomic_write_text(
        scene_embedding_path(slug, scene_id),
        json.dumps({"scene_id": scene_id, "text": text, "vector": vector}),
    )


def has_chunk_embedding(slug: str, chunk_id: str) -> bool:
    return chunk_embedding_path(slug, chunk_id).exists()


def has_scene_embedding(slug: str, scene_id: str) -> bool:
    return scene_embedding_path(slug, scene_id).exists()


# -----------------------------------------------------------------------
# PDF hash — used by the upload endpoint to dedupe re-uploads of the
# same file. Stable across runs and OSes.
# -----------------------------------------------------------------------

def hash_pdf(path: Path | str, *, chunk_size: int = 1 << 20) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            buf = fh.read(chunk_size)
            if not buf:
                break
            h.update(buf)
    return h.hexdigest()


def find_book_by_hash(pdf_hash: str) -> str | None:
    """Return the slug of an existing book whose manifest.source_hash
    matches, or None."""
    root = Path(config.storage_root)
    if not root.exists():
        return None
    for d in root.iterdir():
        if not d.is_dir():
            continue
        manifest = read_manifest(d.name)
        if manifest.get("source_hash") == pdf_hash:
            return d.name
    return None


# -----------------------------------------------------------------------
# Orphan cleanup — chunker IDs are now deterministic, but old random-UUID
# briefs/deeps/chunks/embeddings from prior runs need to be swept so they
# don't pollute the chunk listing or token-cost estimates.
# -----------------------------------------------------------------------

def cleanup_orphans(slug: str, valid_chunk_ids: set[str]) -> dict[str, int]:
    """Delete per-item files whose ID isn't in the current chunker's
    output. Returns {category: count_removed}."""
    book = book_dir(slug)
    removed = {"briefs": 0, "deeps": 0, "chunks": 0, "chunk_embeddings": 0}

    def _sweep(subdir: str, prefix: str = "", suffix: str = ".json") -> int:
        n = 0
        d = book / subdir
        if not d.exists():
            return 0
        for path in d.iterdir():
            if not path.name.endswith(suffix):
                continue
            stem = path.name[len(prefix):-len(suffix)] if prefix else path.stem
            if stem in valid_chunk_ids:
                continue
            try:
                path.unlink()
                n += 1
            except OSError:
                pass
        return n

    removed["briefs"] = _sweep("briefs")
    removed["deeps"] = _sweep("deeps")
    removed["chunks"] = _sweep("chunks")
    removed["chunk_embeddings"] = _sweep("embeddings", prefix="chunk-")
    return removed
