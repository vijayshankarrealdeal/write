"""FastAPI server that wraps the book_ingest CLI tools as HTTP endpoints,
plus serves the single-file React studio at `/`.

Endpoints:
    POST   /api/upload                            multipart PDF upload → kicks off ingest in a background task
    GET    /api/books                             list every book on disk
    GET    /api/books/{slug}                      manifest + counts + chunk index
    GET    /api/books/{slug}/progress             live phase + per-item counters
    GET    /api/books/{slug}/pages                list of page numbers
    GET    /api/books/{slug}/pages/{n}            page text JSON
    GET    /api/books/{slug}/chunks               chunk index (id, title, page range, scene_ids)
    GET    /api/books/{slug}/chunks/{id}          { chunk, brief, deep, delta }
    GET    /api/books/{slug}/images               list of scenes with metadata
    GET    /api/books/{slug}/images/{scene_id}    scene meta (json)
    GET    /api/books/{slug}/images/{scene_id}/png  the PNG itself
    POST   /api/books/{slug}/images/{scene_id}/regenerate  body: {instruction}
    POST   /api/books/{slug}/sync                 run sync_to_db (create user, insert, etc.)
"""

from __future__ import annotations

import asyncio
import json
import re
import sys
from pathlib import Path
from typing import Any

# Make `app.*` (backend imports) and `book_ingest.*` resolvable when this
# module is loaded by uvicorn from the test_model dir.
_HERE = Path(__file__).resolve().parent
_TEST_MODEL = _HERE.parent
_BACKEND_ROOT = _TEST_MODEL.parent
for p in (_BACKEND_ROOT, _TEST_MODEL):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))

from fastapi import BackgroundTasks, FastAPI, HTTPException, UploadFile  # noqa: E402
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse  # noqa: E402
from pydantic import BaseModel  # noqa: E402

from book_ingest import delta as delta_mod  # noqa: E402
from book_ingest import persist  # noqa: E402
from book_ingest.chunker import chunk_pdf  # noqa: E402
from book_ingest.config import config  # noqa: E402
from book_ingest.image_planner import PlannedScene  # noqa: E402
from book_ingest.image_gen import compose_prompt, generate_image  # noqa: E402
from book_ingest.pdf_loader import load_pdf  # noqa: E402
from book_ingest.pipeline import ingest_pdf  # noqa: E402
from book_ingest.schemas import GeneratedScene  # noqa: E402

app = FastAPI(title="Book Ingest Studio")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# -----------------------------------------------------------------------
# In-memory job registry (process-local; resets on server restart).
# Disk state survives independently — this is just for the live progress
# strip in the UI.
# -----------------------------------------------------------------------

_JOBS: dict[str, dict[str, Any]] = {}


def _slug_from_filename(name: str) -> str:
    stem = Path(name).stem
    s = re.sub(r"[^a-zA-Z0-9]+", "-", stem.lower()).strip("-")
    return s or "book"


def _title_from_filename(name: str) -> str:
    stem = Path(name).stem.replace("_", " ").replace("-", " ").strip()
    return stem.title() if stem else name


# -----------------------------------------------------------------------
# Static UI
# -----------------------------------------------------------------------

_INDEX_HTML = _HERE / "static" / "index.html"


@app.get("/", response_class=HTMLResponse)
async def index() -> HTMLResponse:
    if not _INDEX_HTML.exists():
        return HTMLResponse("<h1>studio/static/index.html missing</h1>", status_code=500)
    return HTMLResponse(_INDEX_HTML.read_text(encoding="utf-8"))


# -----------------------------------------------------------------------
# Upload + ingest kickoff
# -----------------------------------------------------------------------

class UploadResponse(BaseModel):
    slug: str
    title: str
    resumed: bool = False
    source_hash: str


@app.post("/api/upload", response_model=UploadResponse)
async def upload_pdf(
    background: BackgroundTasks,
    file: UploadFile,
    title: str | None = None,
    image_budget: int | None = None,
    style: str | None = None,
    reader_preference: str | None = None,
) -> UploadResponse:
    if not file.filename or not file.filename.lower().endswith(".pdf"):
        raise HTTPException(400, "PDF expected")

    # Stream the upload to a scratch file while hashing — same single-pass
    # so a 500 MB PDF never lives in RAM.
    import hashlib
    scratch = Path(config.storage_root) / "_uploads"
    scratch.mkdir(parents=True, exist_ok=True)
    scratch_path = scratch / f"upload-{file.filename}"
    h = hashlib.sha256()
    with open(scratch_path, "wb") as out:
        while chunk := await file.read(1024 * 1024):
            out.write(chunk)
            h.update(chunk)
    source_hash = h.hexdigest()

    # If we've seen this exact PDF before, skip the re-save and resume the
    # existing book's pipeline. This is the "uploaded same as on disk" path.
    existing_slug = persist.find_book_by_hash(source_hash)
    if existing_slug:
        scratch_path.unlink(missing_ok=True)
        manifest = persist.read_manifest(existing_slug)
        slug = existing_slug
        resolved_title = manifest.get("title") or _title_from_filename(file.filename)
        pdf_dest = persist.book_dir(slug) / "source.pdf"
        resumed = True
    else:
        slug = _slug_from_filename(file.filename)
        book_path = persist.book_dir(slug)
        pdf_dest = book_path / "source.pdf"
        scratch_path.replace(pdf_dest)
        manifest = persist.read_manifest(slug) or {}
        manifest["source_hash"] = source_hash
        manifest["source_filename"] = file.filename
        persist.write_manifest(slug, manifest)
        resolved_title = title or _title_from_filename(file.filename)
        resumed = False

    _JOBS[slug] = {
        "phase": "resuming" if resumed else "queued",
        "started": False,
        "error": None,
    }

    background.add_task(
        _run_ingest,
        slug=slug,
        pdf_path=str(pdf_dest),
        title=resolved_title,
        image_budget=image_budget,
        style=style,
        reader_preference=reader_preference,
    )
    return UploadResponse(
        slug=slug,
        title=resolved_title,
        resumed=resumed,
        source_hash=source_hash,
    )


async def _run_ingest(
    slug: str,
    pdf_path: str,
    title: str,
    image_budget: int | None,
    style: str | None,
    reader_preference: str | None,
) -> None:
    _JOBS[slug] = {"phase": "running", "started": True, "error": None}
    try:
        await ingest_pdf(
            pdf_path=pdf_path,
            title=title,
            slug=slug,
            image_budget=image_budget,
            style=style,
            reader_preference=reader_preference,
        )
        _JOBS[slug] = {"phase": "done", "started": True, "error": None}
    except Exception as exc:  # noqa: BLE001
        _JOBS[slug] = {"phase": "failed", "started": True, "error": repr(exc)}


# -----------------------------------------------------------------------
# Book / chunk / page browsing
# -----------------------------------------------------------------------

@app.get("/api/books")
async def list_books() -> dict[str, Any]:
    root = Path(config.storage_root)
    if not root.exists():
        return {"books": []}
    out: list[dict[str, Any]] = []
    for d in sorted(root.iterdir()):
        if not d.is_dir():
            continue
        manifest = persist.read_manifest(d.name)
        if not manifest:
            continue
        out.append({
            "slug": d.name,
            "title": manifest.get("title"),
            "phases_done": manifest.get("phases_done", []),
            "synced": bool(manifest.get("synced")),
        })
    return {"books": out}


@app.get("/api/books/{slug}")
async def get_book(slug: str) -> dict[str, Any]:
    book = persist.book_dir(slug)
    manifest = persist.read_manifest(slug)
    if not manifest:
        raise HTTPException(404, f"unknown slug {slug}")
    chunks = _chunk_index(slug)
    return {
        "slug": slug,
        "manifest": manifest,
        "n_pages": _count_glob(book / "pages", "*.json"),
        "n_briefs": _count_glob(book / "briefs", "*.json"),
        "n_deeps": _count_glob(book / "deeps", "*.json"),
        "n_images": _count_glob(book / "images", "*.png"),
        "chunks": chunks,
    }


@app.get("/api/books/{slug}/progress")
async def progress(slug: str) -> dict[str, Any]:
    book = persist.book_dir(slug)
    manifest = persist.read_manifest(slug)
    job = _JOBS.get(slug, {})
    return {
        "phase": job.get("phase", "unknown"),
        "error": job.get("error"),
        "phases_done": manifest.get("phases_done", []) if manifest else [],
        "n_pages": _count_glob(book / "pages", "*.json"),
        "n_briefs": _count_glob(book / "briefs", "*.json"),
        "n_deeps": _count_glob(book / "deeps", "*.json"),
        "n_chunk_embeddings": _count_glob(book / "embeddings", "chunk-*.json"),
        "n_scene_embeddings": _count_glob(book / "embeddings", "scene-*.json"),
        "n_images": _count_glob(book / "images", "*.png"),
    }


@app.get("/api/books/{slug}/pages")
async def list_pages(slug: str) -> dict[str, Any]:
    book = persist.book_dir(slug)
    pages = sorted(int(p.stem) for p in (book / "pages").glob("*.json"))
    return {"pages": pages}


@app.get("/api/books/{slug}/pages/{n}")
async def get_page(slug: str, n: int) -> dict[str, Any]:
    path = persist.book_dir(slug) / "pages" / f"{n:04d}.json"
    if not path.exists():
        raise HTTPException(404, "page not found")
    return json.loads(path.read_text(encoding="utf-8"))


@app.get("/api/books/{slug}/chunks")
async def list_chunks(slug: str) -> dict[str, Any]:
    return {"chunks": _chunk_index(slug)}


@app.get("/api/books/{slug}/chunks/{chunk_id}")
async def get_chunk(slug: str, chunk_id: str) -> dict[str, Any]:
    payload = persist._safe_read_json(  # type: ignore[attr-defined]
        persist.book_dir(slug) / "chunks" / f"{chunk_id}.json"
    )
    if payload is None:
        raise HTTPException(404, "chunk not found")
    chunk = payload["chunk"]
    deep_dict = payload.get("deep")
    scenes_for_chunk = _scenes_for_chunk(slug, chunk_id)

    # Build the Quill Delta on-the-fly so the user can see what would land
    # in Section.content before sync_to_db.py writes it.
    from book_ingest.schemas import ChunkDeep
    deep_obj = ChunkDeep.model_validate(deep_dict) if deep_dict else None

    pairs: list[tuple[PlannedScene, GeneratedScene]] = [
        (
            PlannedScene(
                scene_id=s["scene_id"],
                chunk_id=chunk_id,
                chapter_title=s.get("chapter_title"),
                scene_text=s.get("scene_text", ""),
                score=float(s.get("score", 0.0)),
            ),
            GeneratedScene(
                scene_id=s["scene_id"],
                chunk_id=chunk_id,
                prompt=s.get("prompt", ""),
                image_path=s.get("image_path", ""),
            ),
        )
        for s in scenes_for_chunk
    ]
    delta = delta_mod.build_section_delta(
        chunk_text=chunk["text"],
        deep=deep_obj,
        scenes_in_chunk=pairs,
        image_url_for=lambda local: f"/api/books/{slug}/images/{Path(local).stem}/png",
    )
    return {**payload, "delta": delta, "scenes": scenes_for_chunk}


# -----------------------------------------------------------------------
# Whole-book Delta — the "reading experience" feed
# -----------------------------------------------------------------------

# In-memory cache for the (expensive) full-book Delta. Keyed by slug;
# invalidated when chunks/ or images/ mtime changes.
_DELTA_CACHE: dict[str, tuple[float, dict[str, Any]]] = {}


def _book_state_mtime(slug: str) -> float:
    """Latest mtime across the dirs the delta depends on. Cheap — just
    `stat()` per file in two directories. ~1ms even for 1500 files."""
    book = persist.book_dir(slug)
    latest = 0.0
    for sub in ("chunks", "images"):
        d = book / sub
        if not d.exists():
            continue
        try:
            for entry in d.iterdir():
                m = entry.stat().st_mtime
                if m > latest:
                    latest = m
        except OSError:
            pass
    return latest


@app.get("/api/books/{slug}/delta")
async def get_full_delta(slug: str) -> dict[str, Any]:
    """Return every chunk's Quill Delta in reading order. Cached in
    memory; invalidates when any chunk or image file changes."""
    book = persist.book_dir(slug)
    manifest = persist.read_manifest(slug)
    if not manifest:
        raise HTTPException(404, f"unknown slug {slug}")

    mtime = _book_state_mtime(slug)
    cached = _DELTA_CACHE.get(slug)
    if cached and cached[0] == mtime:
        return cached[1]

    # Build a chunk_id → scenes index ONCE, instead of scanning all images
    # for every chunk (was O(chunks × images), now O(images)).
    scenes_by_chunk: dict[str, list[dict[str, Any]]] = {}
    for meta_path in (book / "images").glob("*.json"):
        meta = persist._safe_read_json(meta_path)  # type: ignore[attr-defined]
        if not meta:
            continue
        cid = meta.get("chunk_id")
        if cid:
            scenes_by_chunk.setdefault(cid, []).append(meta)
    for cid in scenes_by_chunk:
        scenes_by_chunk[cid].sort(key=lambda m: m.get("score") or 0, reverse=True)

    chunk_payloads: list[dict[str, Any]] = []
    for path in (book / "chunks").glob("*.json"):
        payload = persist._safe_read_json(path)  # type: ignore[attr-defined]
        if payload:
            chunk_payloads.append(payload)
    chunk_payloads.sort(key=lambda p: (p["chunk"]["page_start"], p["chunk"]["page_end"]))

    from book_ingest.schemas import ChunkDeep

    chapters: list[dict[str, Any]] = []
    for payload in chunk_payloads:
        c = payload["chunk"]
        deep_dict = payload.get("deep")
        deep_obj = ChunkDeep.model_validate(deep_dict) if deep_dict else None

        scenes_for_chunk = scenes_by_chunk.get(c["id"], [])
        pairs: list[tuple[PlannedScene, GeneratedScene]] = [
            (
                PlannedScene(
                    scene_id=s["scene_id"],
                    chunk_id=c["id"],
                    chapter_title=s.get("chapter_title"),
                    scene_text=s.get("scene_text", ""),
                    score=float(s.get("score", 0.0)),
                ),
                GeneratedScene(
                    scene_id=s["scene_id"],
                    chunk_id=c["id"],
                    prompt=s.get("prompt", ""),
                    image_path=s.get("image_path", ""),
                ),
            )
            for s in scenes_for_chunk
        ]
        ops = delta_mod.build_section_delta(
            chunk_text=c["text"],
            deep=deep_obj,
            scenes_in_chunk=pairs,
            image_url_for=lambda local: f"/api/books/{slug}/images/{Path(local).stem}/png",
        )
        chapters.append({
            "id": c["id"],
            "title": c.get("chapter_title"),
            "page_start": c["page_start"],
            "page_end": c["page_end"],
            "char_count": len(c.get("text") or ""),
            "ops": ops,
            "scene_ids": [s["scene_id"] for s in scenes_for_chunk],
            "rich_summary": deep_dict.get("rich_summary") if deep_dict else None,
        })

    result = {
        "title": manifest.get("title"),
        "author": manifest.get("author"),
        "style": manifest.get("style"),
        "chapters": chapters,
    }
    _DELTA_CACHE[slug] = (mtime, result)
    return result


# -----------------------------------------------------------------------
# Images: list, fetch, regenerate
# -----------------------------------------------------------------------

@app.get("/api/books/{slug}/images")
async def list_images(slug: str) -> dict[str, Any]:
    book = persist.book_dir(slug)

    # Build a chunk_id → page-range index so each image carries its page span.
    chunk_pages: dict[str, tuple[int, int]] = {}
    for path in (book / "chunks").glob("*.json"):
        payload = persist._safe_read_json(path)  # type: ignore[attr-defined]
        if payload:
            c = payload["chunk"]
            chunk_pages[c["id"]] = (c["page_start"], c["page_end"])

    out: list[dict[str, Any]] = []
    for meta_path in sorted((book / "images").glob("*.json")):
        meta = persist._safe_read_json(meta_path)  # type: ignore[attr-defined]
        if not meta:
            continue
        sid = meta.get("scene_id") or meta_path.stem
        cid = meta.get("chunk_id")
        ps, pe = chunk_pages.get(cid, (None, None))
        out.append({
            "scene_id": sid,
            "chunk_id": cid,
            "chapter_title": meta.get("chapter_title"),
            "page_start": ps,
            "page_end": pe,
            "score": meta.get("score"),
            "scene_text": meta.get("scene_text"),
            "url": f"/api/books/{slug}/images/{sid}/png",
            "revision_count": len(meta.get("revision_history") or []),
        })
    out.sort(key=lambda m: m.get("score") or 0, reverse=True)
    return {"images": out}


@app.get("/api/books/{slug}/images/{scene_id}")
async def get_image_meta(slug: str, scene_id: str) -> dict[str, Any]:
    meta = persist.read_scene_meta(slug, scene_id)
    if not meta:
        raise HTTPException(404, "scene not found")
    return meta


@app.get("/api/books/{slug}/images/{scene_id}/png")
async def get_image_png(slug: str, scene_id: str) -> FileResponse:
    p = persist.image_path_for(slug, scene_id)
    if not p.exists():
        raise HTTPException(404, "png not found")
    return FileResponse(p, media_type="image/png")


class RegenerateBody(BaseModel):
    instruction: str | None = None


@app.post("/api/books/{slug}/images/{scene_id}/regenerate")
async def regenerate(slug: str, scene_id: str, body: RegenerateBody) -> dict[str, Any]:
    from datetime import datetime, timezone

    meta = persist.read_scene_meta(slug, scene_id)
    if not meta:
        raise HTTPException(404, "scene not found")
    manifest = persist.read_manifest(slug)
    style = manifest.get("style")
    reader_preference = manifest.get("reader_preference")

    original_scene = meta.get("scene_text", "")
    instruction = (body.instruction or "").strip()
    composed = (
        f"{original_scene}. Modification: {instruction}" if instruction else original_scene
    )

    out_path = persist.image_path_for(slug, scene_id)
    backup = None
    if out_path.exists():
        ts = datetime.now().strftime("%Y%m%dT%H%M%S")
        backup = out_path.with_suffix(f".{ts}.bak.png")
        out_path.replace(backup)

    await generate_image(
        composed,
        str(out_path),
        style=style,
        reader_preference=reader_preference,
    )

    history = list(meta.get("revision_history") or [])
    history.append({
        "ts": datetime.now(timezone.utc).isoformat(),
        "instruction": instruction,
        "previous_prompt": meta.get("prompt"),
        "previous_backup": str(backup) if backup else None,
    })
    meta["revision_history"] = history
    meta["prompt"] = compose_prompt(composed, style=style, reader_preference=reader_preference)
    meta["scene_text"] = composed
    persist._atomic_write_text(  # type: ignore[attr-defined]
        persist.scene_meta_path(slug, scene_id),
        json.dumps(meta, indent=2),
    )
    return {"ok": True, "scene_id": scene_id, "revisions": len(history)}


# -----------------------------------------------------------------------
# Orphan cleanup — sweeps stale per-item files (random-UUID briefs/deeps
# from before the deterministic-chunker switch) by re-running the chunker
# and deleting anything whose id isn't in the current set.
# -----------------------------------------------------------------------

@app.post("/api/books/{slug}/cleanup-orphans")
async def cleanup_orphans(slug: str) -> dict[str, Any]:
    book = persist.book_dir(slug)
    pdf = book / "source.pdf"
    if not pdf.exists():
        raise HTTPException(404, f"source.pdf missing for {slug}")
    loaded = load_pdf(str(pdf))
    chunks = chunk_pdf(loaded)
    valid = {c.id for c in chunks}
    removed = persist.cleanup_orphans(slug, valid)
    return {
        "slug": slug,
        "chunks_kept": len(valid),
        "removed": removed,
        "total_removed": sum(removed.values()),
    }


# -----------------------------------------------------------------------
# Sync to DB + MinIO
# -----------------------------------------------------------------------

class SyncBody(BaseModel):
    force: bool = False
    no_images: bool = False


@app.post("/api/books/{slug}/sync")
async def sync(slug: str, body: SyncBody) -> dict[str, Any]:
    """Runs the same code path as `sync_to_db.py`. Re-uses the disk dump
    so this endpoint is safe to retry."""
    proc = await asyncio.create_subprocess_exec(
        sys.executable,
        str(_TEST_MODEL / "sync_to_db.py"),
        slug,
        *(["--force"] if body.force else []),
        *(["--no-images"] if body.no_images else []),
        cwd=str(_TEST_MODEL),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    out, _ = await proc.communicate()
    text = out.decode("utf-8", errors="replace")
    return JSONResponse(
        {"ok": proc.returncode == 0, "exit": proc.returncode, "output": text}
    )


# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------

def _count_glob(directory: Path, pattern: str) -> int:
    if not directory.exists():
        return 0
    return sum(1 for _ in directory.glob(pattern))


def _chunk_index(slug: str) -> list[dict[str, Any]]:
    book = persist.book_dir(slug)
    out: list[dict[str, Any]] = []
    for path in sorted((book / "chunks").glob("*.json")):
        payload = persist._safe_read_json(path)  # type: ignore[attr-defined]
        if not payload:
            continue
        c = payload["chunk"]
        out.append({
            "id": c["id"],
            "chapter_title": c.get("chapter_title"),
            "page_start": c["page_start"],
            "page_end": c["page_end"],
            "char_count": len(c.get("text") or ""),
            "has_brief": payload.get("brief") is not None,
            "has_deep": payload.get("deep") is not None,
            "scene_ids": payload.get("scene_ids") or [],
        })
    out.sort(key=lambda x: (x["page_start"], x["page_end"]))
    return out


def _scenes_for_chunk(slug: str, chunk_id: str) -> list[dict[str, Any]]:
    book = persist.book_dir(slug)
    out: list[dict[str, Any]] = []
    for path in (book / "images").glob("*.json"):
        meta = persist._safe_read_json(path)  # type: ignore[attr-defined]
        if not meta or meta.get("chunk_id") != chunk_id:
            continue
        out.append(meta)
    out.sort(key=lambda m: m.get("score") or 0, reverse=True)
    return out
