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
from typing import Any, Literal

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

from pydantic_ai import Agent  # noqa: E402

from book_ingest import cleaner as cleaner_mod  # noqa: E402
from book_ingest import delta as delta_mod  # noqa: E402
from book_ingest import persist  # noqa: E402
from book_ingest.agents import cleaner_model  # noqa: E402
from book_ingest.chunker import chunk_pdf  # noqa: E402
from book_ingest.config import config  # noqa: E402
from book_ingest.image_planner import PlannedScene  # noqa: E402
from book_ingest.image_gen import compose_prompt, generate_image  # noqa: E402
from book_ingest.pdf_loader import load_pdf  # noqa: E402
from book_ingest.pipeline import ingest_pdf  # noqa: E402
from book_ingest.retry import with_retries  # noqa: E402
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
    # Disable HTTP caching so the dev studio always serves fresh markup —
    # otherwise the browser holds the previous index.html across reloads
    # and edits to the React/JSX code never appear.
    return HTMLResponse(
        _INDEX_HTML.read_text(encoding="utf-8"),
        headers={
            "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
            "Pragma": "no-cache",
            "Expires": "0",
        },
    )


# -----------------------------------------------------------------------
# Upload + ingest kickoff
# -----------------------------------------------------------------------

class UploadResponse(BaseModel):
    slug: str
    title: str
    resumed: bool = False
    source_hash: str


_ACCEPTED_EXTS = (".pdf", ".html", ".htm")


@app.post("/api/upload", response_model=UploadResponse)
async def upload_pdf(
    background: BackgroundTasks,
    file: UploadFile,
    title: str | None = None,
    image_budget: int | None = None,
    style: str | None = None,
    reader_preference: str | None = None,
) -> UploadResponse:
    fname = (file.filename or "").lower()
    if not fname.endswith(_ACCEPTED_EXTS):
        raise HTTPException(400, "PDF or HTML expected (.pdf / .html / .htm)")

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

    # Pick the right on-disk extension for the source file. The ingest
    # pipeline routes on extension (".html"/".htm" → html_loader, ".pdf"
    # → pdf_loader), so we preserve the input format.
    src_ext = ".html" if fname.endswith((".html", ".htm")) else ".pdf"

    # If we've seen this exact source before, skip the re-save and resume
    # the existing book's pipeline. This is the "uploaded same as on
    # disk" path.
    existing_slug = persist.find_book_by_hash(source_hash)
    if existing_slug:
        scratch_path.unlink(missing_ok=True)
        manifest = persist.read_manifest(existing_slug)
        slug = existing_slug
        display_title = manifest.get("title") or _title_from_filename(file.filename)
        # Find whichever source.<ext> already exists for this book.
        book_path = persist.book_dir(slug)
        candidates = [book_path / f"source{ext}" for ext in (".pdf", ".html", ".htm")]
        pdf_dest = next((p for p in candidates if p.exists()), book_path / f"source{src_ext}")
        resumed = True
    else:
        slug = _slug_from_filename(file.filename)
        book_path = persist.book_dir(slug)
        pdf_dest = book_path / f"source{src_ext}"
        scratch_path.replace(pdf_dest)
        manifest = persist.read_manifest(slug) or {}
        manifest["source_hash"] = source_hash
        manifest["source_filename"] = file.filename
        manifest["source_format"] = "html" if src_ext == ".html" else "pdf"
        persist.write_manifest(slug, manifest)
        display_title = title or _title_from_filename(file.filename)
        resumed = False

    _JOBS[slug] = {
        "phase": "resuming" if resumed else "queued",
        "started": False,
        "error": None,
    }

    # IMPORTANT: only the user's explicit `title` (from the form) goes
    # to the pipeline. If they didn't override, pass None — that lets
    # `ingest_pdf` use the title the HTML loader extracts from the
    # Gutenberg <meta name="dc.title"> / <title> tags. Otherwise the
    # filename-derived title ("Pg64317 Images") would short-circuit
    # the `title or loader_title or slug` chain and stomp the real
    # "The Great Gatsby" before it ever has a chance to apply.
    background.add_task(
        _run_ingest,
        slug=slug,
        pdf_path=str(pdf_dest),
        title=title,
        image_budget=image_budget,
        style=style,
        reader_preference=reader_preference,
    )
    return UploadResponse(
        slug=slug,
        title=display_title,
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
            "vm_upload_done": bool(manifest.get("vm_upload_done")),
            "vm_upload_done_utc": manifest.get("vm_upload_done_utc"),
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
        cleaned_markdown=cleaner_mod.get_cleaned_text(slug, chunk_id),
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
            cleaned_markdown=cleaner_mod.get_cleaned_text(slug, c["id"]),
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
    orphan_count = 0
    for meta_path in sorted((book / "images").glob("*.json")):
        meta = persist._safe_read_json(meta_path)  # type: ignore[attr-defined]
        if not meta:
            continue
        sid = meta.get("scene_id") or meta_path.stem
        cid = meta.get("chunk_id")
        # An image is an "orphan" when its chunk_id no longer matches any
        # chunk on disk (typical cause: chunker re-ran with different
        # IDs, e.g. random-UUID → deterministic). The image file is fine,
        # but it has no page mapping. Surfacing this lets the user
        # decide whether to clean it up via /cleanup-orphans?images=true
        # or keep it (image regen is expensive).
        is_orphan = cid is not None and cid not in chunk_pages
        ps, pe = chunk_pages.get(cid, (None, None))
        if is_orphan:
            orphan_count += 1
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
            "orphan": is_orphan,
        })
    out.sort(key=lambda m: m.get("score") or 0, reverse=True)
    return {"images": out, "orphans": orphan_count}


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
async def cleanup_orphans(slug: str, include_images: bool = False) -> dict[str, Any]:
    """Sweep stale per-item files. By default only briefs/deeps/chunks/
    embeddings are touched (those are cheap to regenerate). Pass
    `include_images=true` to also delete orphan image .png + .json
    files — use this when you've re-chunked and don't intend to keep
    images that no longer attach to any chunk."""
    book = persist.book_dir(slug)
    src = next(
        (book / f"source{ext}" for ext in (".pdf", ".html", ".htm") if (book / f"source{ext}").exists()),
        None,
    )
    if src is None:
        raise HTTPException(404, f"source.pdf/html missing for {slug}")
    # The chunker takes the loader output regardless of source format,
    # so we route to the right loader on extension here.
    if src.suffix.lower() in (".html", ".htm"):
        from book_ingest.html_loader import load_html
        loaded_html = load_html(str(src))
        from book_ingest.pdf_loader import LoadedPdf
        loaded = LoadedPdf(pages=loaded_html.pages, toc=list(loaded_html.toc))
    else:
        loaded = load_pdf(str(src))
    chunks = chunk_pdf(loaded)
    valid = {c.id for c in chunks}
    removed = persist.cleanup_orphans(slug, valid)

    if include_images:
        img_removed = 0
        img_dir = book / "images"
        if img_dir.exists():
            for meta_path in img_dir.glob("*.json"):
                meta = persist._safe_read_json(meta_path)  # type: ignore[attr-defined]
                cid = (meta or {}).get("chunk_id")
                if cid in valid:
                    continue
                # Orphan — drop both the meta and the matching png.
                stem = meta_path.stem
                png = img_dir / f"{stem}.png"
                for p in (meta_path, png):
                    try:
                        if p.exists():
                            p.unlink()
                            if p.suffix == ".png":
                                img_removed += 1
                    except OSError:
                        pass
        removed["images"] = img_removed

    return {
        "slug": slug,
        "chunks_kept": len(valid),
        "removed": removed,
        "total_removed": sum(removed.values()),
    }


# -----------------------------------------------------------------------
# Final cleanup — re-run the cleaner pass over every chunk with the user's
# free-form instruction appended to the prompt. Lets the user say things
# like "drop the running header 'SHRI SHIVA PURANA' from every page" or
# "merge mid-sentence line breaks more aggressively" without editing the
# pipeline. The job runs in the background; the existing /progress poll
# surfaces phase = "final-cleanup" and per-chunk completion via n_pages
# stays the same — we expose new counters in /final-cleanup/status.
# -----------------------------------------------------------------------

class FinalCleanupBody(BaseModel):
    instruction: str


_FINAL_CLEANUP_STATE: dict[str, dict[str, Any]] = {}


@app.post("/api/books/{slug}/final-cleanup")
async def final_cleanup(
    slug: str,
    body: FinalCleanupBody,
    background: BackgroundTasks,
) -> dict[str, Any]:
    instruction = (body.instruction or "").strip()
    if not instruction:
        raise HTTPException(400, "instruction required")
    manifest = persist.read_manifest(slug)
    if not manifest:
        raise HTTPException(404, f"unknown slug {slug}")

    # Persist the instruction so re-runs of the pipeline can pick it up
    # and so the studio can show it back to the user later.
    history = list(manifest.get("final_cleanup_history") or [])
    from datetime import datetime, timezone
    history.append({
        "ts": datetime.now(timezone.utc).isoformat(),
        "instruction": instruction,
    })
    manifest["final_cleanup_instruction"] = instruction
    manifest["final_cleanup_history"] = history
    persist.write_manifest(slug, manifest)

    state = _FINAL_CLEANUP_STATE.get(slug) or {}
    if state.get("phase") == "running":
        return {"ok": False, "queued": False, "reason": "already running"}

    _FINAL_CLEANUP_STATE[slug] = {
        "phase": "queued",
        "instruction": instruction,
        "completed": 0,
        "total": 0,
        "error": None,
    }
    background.add_task(_run_final_cleanup, slug=slug, instruction=instruction)
    return {"ok": True, "queued": True, "instruction": instruction}


@app.get("/api/books/{slug}/final-cleanup/status")
async def final_cleanup_status(slug: str) -> dict[str, Any]:
    state = _FINAL_CLEANUP_STATE.get(slug) or {"phase": "idle"}
    manifest = persist.read_manifest(slug) or {}
    return {
        **state,
        "last_instruction": manifest.get("final_cleanup_instruction"),
        "history": manifest.get("final_cleanup_history") or [],
    }


class CleanupPlan(BaseModel):
    """Router output: how to apply the user's free-form instruction.

    The point of routing is cost. A book has ~50–500 chunks and an LLM
    pass over each costs real money. Many of the cleanups users actually
    want — "drop the running header SHRI SHIVA PURANA", "convert ' to ’",
    "strip page numbers" — are pure find/replace; one regex applied
    locally beats N LLM calls. The router decides.
    """
    method: Literal["regex", "llm"]
    rationale: str
    regex_pattern: str | None = None
    regex_replacement: str | None = None
    regex_flags: list[str] | None = None  # subset of: IGNORECASE, MULTILINE, DOTALL


_ROUTER_PROMPT = (
    "You route book-text cleanup instructions. STRONGLY PREFER 'regex'.\n\n"
    "COST CONTEXT — read this before deciding:\n"
    "  A book has 50-500 chunks. 'llm' means an LLM call PER CHUNK "
    "(50-500 calls, real money, slow). 'regex' is ONE call (yours, now) "
    "then a deterministic find/replace applied locally — free and instant.\n"
    "  Default to 'regex'. Only choose 'llm' when the cleanup truly "
    "cannot be expressed as a pattern.\n\n"
    "INPUT — you receive:\n"
    "  1. The user's free-form instruction\n"
    "  2. REPRESENTATIVE TEXT SAMPLES from the book (first/middle/last "
    "chunks). USE THESE. Don't guess what the pattern looks like — "
    "read the samples to find the exact form: capitalisation, spacing, "
    "line breaks, surrounding context. The pattern you produce must "
    "match what's ACTUALLY in the text, not what you imagine.\n\n"
    "Choose 'regex' for (this list is non-exhaustive):\n"
    "  • duplicated text (e.g. title appearing twice in a row)\n"
    "  • running headers / footers, page numbers, watermarks\n"
    "  • footnote markers ([1], †, *), URL patterns, email addresses\n"
    "  • punctuation normalisation (smart quotes, em-dashes, ellipses)\n"
    "  • repeated whitespace, blank-line collapsing\n"
    "  • stripping a recurring marker visible in the samples\n"
    "  • ANY find/replace you can express after reading the samples\n\n"
    "Choose 'llm' ONLY when the cleanup needs reading comprehension that "
    "no regex can capture:\n"
    "  • merge mid-sentence line breaks (depends on sentence semantics)\n"
    "  • rewrite for tone, clarity, modern English\n"
    "  • fix grammar requiring context\n"
    "  • subjective reformulation\n\n"
    "REGEX RULES:\n"
    "  • emit a Python re.sub-compatible pattern + replacement\n"
    "  • use raw-string-safe syntax (no leading r-prefix, just escape "
    "backslashes if needed)\n"
    "  • the pattern runs against each chunk's cleaned markdown\n"
    "  • use MULTILINE if you need ^/$ to match per line\n"
    "  • use DOTALL if . needs to match newlines\n"
    "  • IGNORECASE when capitalisation in the samples varies\n"
    "  • prefer SPECIFIC patterns over greedy ones — false positives "
    "delete real prose. Anchor with surrounding context where possible.\n"
    "  • for a duplicated phrase, use a backreference: e.g. "
    "`(SIVA PURANAM)\\s+\\1` → `\\1`\n\n"
    "regex_flags: subset of [IGNORECASE, MULTILINE, DOTALL]. Empty list "
    "or omit if none needed.\n\n"
    "rationale: ONE sentence. Cite a sample line if it helped you decide."
)


# How much representative text we hand the router. Three samples × 1500 chars
# is enough to spot recurring headers/footers/duplications without blowing
# the context budget on books with hundred-page chapters.
_ROUTER_SAMPLE_CHUNKS = 5
_ROUTER_SAMPLE_CHARS = 1500


def _sample_text_for_router(slug: str) -> str:
    """Pull a few representative chunks (evenly spaced through the book)
    and concatenate their cleaned text. Gives the router actual patterns
    to match — vs. forcing it to guess from the user's prose alone."""
    book = persist.book_dir(slug)
    chunk_files = sorted((book / "chunks").glob("*.json"))
    if not chunk_files:
        return ""

    # Even spacing — first, last, plus middle picks. For short books
    # (<= n_chunks chunks) we just use them all.
    n = _ROUTER_SAMPLE_CHUNKS
    if len(chunk_files) <= n:
        sampled = chunk_files
    else:
        # Pick indices that include 0 and len-1 explicitly so first and
        # last chapters are always represented.
        idxs = [round(i * (len(chunk_files) - 1) / (n - 1)) for i in range(n)]
        # Dedup while preserving order in case of rounding collisions.
        seen: set[int] = set()
        sampled = []
        for i in idxs:
            if i in seen:
                continue
            seen.add(i)
            sampled.append(chunk_files[i])

    parts: list[str] = []
    for path in sampled:
        payload = persist._safe_read_json(path)  # type: ignore[attr-defined]
        if not payload:
            continue
        c = payload["chunk"]
        text = cleaner_mod.get_cleaned_text(slug, c["id"]) or c.get("text") or ""
        parts.append(
            f"--- chunk {c['id']} (pages {c.get('page_start')}–{c.get('page_end')}) ---\n"
            f"{text[:_ROUTER_SAMPLE_CHARS]}"
        )
    return "\n\n".join(parts)

_router_agent: Agent[None, CleanupPlan] = Agent(
    model=cleaner_model,
    output_type=CleanupPlan,
    system_prompt=_ROUTER_PROMPT,
)


def _compile_flags(names: list[str] | None) -> int:
    flags = 0
    for n in (names or []):
        attr = getattr(re, n.strip().upper(), None)
        if isinstance(attr, int):
            flags |= attr
    return flags


async def _run_final_cleanup(slug: str, instruction: str) -> None:
    """Decide regex-vs-llm via the router, then apply.

    Regex path  — 1 LLM call total. Apply re.sub to every chunk's
                  cleaned markdown (or raw text fallback).
    LLM path    — 1 router call + 1 cleaner call per chunk. Surgical
                  rewrite of each chunk with the instruction.

    Either way, writes back to cleaned/{chunk_id}.md so the next /delta
    render reflects the change. Best-effort per chunk — failures are
    logged and skipped."""
    book = persist.book_dir(slug)
    chunk_files = sorted((book / "chunks").glob("*.json"))

    state = _FINAL_CLEANUP_STATE.setdefault(slug, {})
    state.update({
        "phase": "running",
        "instruction": instruction,
        "completed": 0,
        "total": len(chunk_files),
        "error": None,
        "plan": None,
    })

    # 1) Route. Feed the router actual text samples so it can produce a
    # pattern that matches what's really in the book — not what it
    # imagines based on the user's instruction alone.
    sample = _sample_text_for_router(slug)
    router_input = (
        f"USER INSTRUCTION:\n{instruction}\n\n"
        f"REPRESENTATIVE TEXT SAMPLES (read these to design the pattern):\n\n"
        f"{sample}"
    ) if sample else instruction

    try:
        plan_run = await with_retries(
            lambda: _router_agent.run(router_input),
            label="final-cleanup-router",
        )
        plan = plan_run.output
    except Exception as exc:  # noqa: BLE001
        # Router failure → fall back to llm path so the user still gets
        # *something* applied. Surface the error.
        print(f"[final-cleanup] router failed: {exc} — falling back to llm")
        plan = CleanupPlan(method="llm", rationale=f"router-error: {exc}")

    state["plan"] = plan.model_dump()

    # 2) Apply.
    if plan.method == "regex" and plan.regex_pattern:
        try:
            pat = re.compile(plan.regex_pattern, _compile_flags(plan.regex_flags))
        except re.error as exc:
            print(f"[final-cleanup] regex compile failed: {exc} — falling back to llm")
            plan = CleanupPlan(
                method="llm",
                rationale=f"regex-compile-error: {exc}",
                regex_pattern=plan.regex_pattern,
                regex_replacement=plan.regex_replacement,
                regex_flags=plan.regex_flags,
            )
            state["plan"] = plan.model_dump()

    if plan.method == "regex" and plan.regex_pattern:
        repl = plan.regex_replacement or ""
        for path in chunk_files:
            payload = persist._safe_read_json(path)  # type: ignore[attr-defined]
            if not payload:
                state["completed"] = state.get("completed", 0) + 1
                continue
            c = payload["chunk"]
            prior = cleaner_mod.get_cleaned_text(slug, c["id"]) or c.get("text") or ""
            try:
                new_text = pat.sub(repl, prior)
                if new_text != prior:
                    cleaner_mod._save_cleaned(slug, c["id"], new_text)  # type: ignore[attr-defined]
            except Exception as exc:  # noqa: BLE001
                print(f"[final-cleanup] regex apply {c['id']} failed: {exc}")
            state["completed"] = state.get("completed", 0) + 1
    else:
        # LLM path — per-chunk surgical rewrite.
        for path in chunk_files:
            payload = persist._safe_read_json(path)  # type: ignore[attr-defined]
            if not payload:
                state["completed"] = state.get("completed", 0) + 1
                continue
            c = payload["chunk"]
            prior = cleaner_mod.get_cleaned_text(slug, c["id"]) or c.get("text") or ""
            prior = prior[:30_000]
            prompt = (
                f"USER INSTRUCTION FOR FINAL CLEANUP: {instruction}\n\n"
                f"Apply the instruction above while keeping every other "
                f"cleaning rule. The text below is the current cleaned "
                f"version — do not re-summarise or re-paraphrase, just "
                f"surgically apply the user's instruction and re-output "
                f"the full text as markdown.\n\n"
                f"---\n\n"
                f"{prior}"
            )
            try:
                run = await with_retries(
                    lambda p=prompt: cleaner_mod.cleaner_agent.run(p),
                    label=f"final-cleanup[{c['id']}]",
                )
                cleaner_mod._save_cleaned(slug, c["id"], run.output.markdown)  # type: ignore[attr-defined]
            except Exception as exc:  # noqa: BLE001
                print(f"[final-cleanup] {c['id']} failed: {exc}")
            state["completed"] = state.get("completed", 0) + 1

    # Bust the in-memory delta cache so the next /delta call rebuilds
    # against the updated cleaned/ files.
    _DELTA_CACHE.pop(slug, None)
    state["phase"] = "done"


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
# Remote publish — push the locally-ingested book to a public inkspacex
# deployment via its REST API. No MinIO / Postgres on the studio side;
# the studio just authenticates as a user and dumps everything through
# the same endpoints a Flutter or web client uses.
#
# Contrast with `/sync` above which calls sync_to_db.py — that one
# requires MinIO running on localhost:9000 and direct DB access.
# `/sync-remote` requires only network access to api.inkspacex.com.
# -----------------------------------------------------------------------

class SyncRemoteBody(BaseModel):
    api_url: str = "https://api.inkspacex.com"
    email: str
    password: str


_REMOTE_SYNC_STATE: dict[str, dict[str, Any]] = {}


@app.post("/api/books/{slug}/sync-remote")
async def sync_remote(
    slug: str,
    body: SyncRemoteBody,
    background: BackgroundTasks,
) -> dict[str, Any]:
    if not body.email or not body.password:
        raise HTTPException(400, "email + password required")
    manifest = persist.read_manifest(slug)
    if not manifest:
        raise HTTPException(404, f"unknown slug {slug}")

    state = _REMOTE_SYNC_STATE.get(slug) or {}
    if state.get("phase") in ("running", "queued"):
        return {"ok": False, "queued": False, "reason": "already running"}

    _REMOTE_SYNC_STATE[slug] = {
        "phase": "queued",
        "api_url": body.api_url,
        "email": body.email,
        "events": [],
        "error": None,
        "result": None,
    }
    background.add_task(
        _run_remote_sync,
        slug=slug,
        api_url=body.api_url,
        email=body.email,
        password=body.password,
    )
    return {"ok": True, "queued": True}


@app.get("/api/books/{slug}/sync-remote/status")
async def sync_remote_status(slug: str) -> dict[str, Any]:
    state = _REMOTE_SYNC_STATE.get(slug) or {"phase": "idle", "events": []}
    # Strip the email from the public status so the password-adjacent
    # field doesn't echo back into UI screenshots.
    public = {**state}
    public.pop("email", None)
    return public


async def _run_remote_sync(
    slug: str, *, api_url: str, email: str, password: str,
) -> None:
    from . import remote_publish

    state = _REMOTE_SYNC_STATE.setdefault(slug, {})
    state["phase"] = "running"
    state["events"] = []

    def _record(name: str, payload: dict[str, Any]) -> None:
        # Cap the event log so a chatty publish doesn't accumulate
        # forever in the in-memory state.
        evs = state.setdefault("events", [])
        evs.append({"name": name, "payload": payload})
        if len(evs) > 200:
            del evs[: len(evs) - 200]

    try:
        result = await remote_publish.publish_book(
            slug,
            api_url=api_url,
            email=email,
            password=password,
            on_event=_record,
        )
        state["result"] = result
        state["phase"] = "done"
    except remote_publish.RemotePublishError as exc:
        state["error"] = {"message": str(exc), "status": exc.status, "body": exc.body}
        state["phase"] = "failed"
    except Exception as exc:  # noqa: BLE001
        state["error"] = {"message": repr(exc)}
        state["phase"] = "failed"


# -----------------------------------------------------------------------
# VM publish — SSH + SCP path. Bundles the local storage/{slug}/ dir,
# uploads via SFTP, runs sync_to_db.py on the VM. Best for bulk loads
# or when api.inkspacex.com is rate-limiting us. See vm_publish.py for
# the full design rationale.
# -----------------------------------------------------------------------

class SyncVmBody(BaseModel):
    vm_ip: str = "20.219.16.30"
    username: str = "azureuser"
    password: str
    remote_backend_root: str = "/home/azureuser/write/backend"
    remote_storage_subdir: str = "test_model/storage/books"
    force: bool = True  # default True since the VM-path is usually the "fix it for real" sync


_VM_SYNC_STATE: dict[str, dict[str, Any]] = {}


@app.post("/api/books/{slug}/sync-vm")
async def sync_vm(
    slug: str,
    body: SyncVmBody,
    background: BackgroundTasks,
) -> dict[str, Any]:
    if not body.password:
        raise HTTPException(400, "password required")
    manifest = persist.read_manifest(slug)
    if not manifest:
        raise HTTPException(404, f"unknown slug {slug}")

    state = _VM_SYNC_STATE.get(slug) or {}
    if state.get("phase") in ("running", "queued"):
        return {"ok": False, "queued": False, "reason": "already running"}

    _VM_SYNC_STATE[slug] = {
        "phase": "queued",
        "vm_ip": body.vm_ip,
        "username": body.username,
        "events": [],
        "error": None,
        "result": None,
    }
    background.add_task(
        _run_vm_sync,
        slug=slug,
        vm_ip=body.vm_ip,
        username=body.username,
        password=body.password,
        remote_backend_root=body.remote_backend_root,
        remote_storage_subdir=body.remote_storage_subdir,
        force=body.force,
    )
    return {"ok": True, "queued": True}


@app.get("/api/books/{slug}/sync-vm/status")
async def sync_vm_status(slug: str) -> dict[str, Any]:
    state = _VM_SYNC_STATE.get(slug) or {"phase": "idle", "events": []}
    # Strip nothing here — username + vm_ip are non-sensitive operational
    # context the user wants to see in the UI.
    return {**state}


async def _run_vm_sync(
    slug: str, *,
    vm_ip: str,
    username: str,
    password: str,
    remote_backend_root: str,
    remote_storage_subdir: str,
    force: bool,
) -> None:
    from . import vm_publish

    state = _VM_SYNC_STATE.setdefault(slug, {})
    state["phase"] = "running"
    state["events"] = []

    def _record(name: str, payload: dict[str, Any]) -> None:
        evs = state.setdefault("events", [])
        evs.append({"name": name, "payload": payload})
        if len(evs) > 400:
            del evs[: len(evs) - 400]

    try:
        result = await vm_publish.publish_to_vm(
            slug,
            vm_ip=vm_ip,
            username=username,
            password=password,
            remote_backend_root=remote_backend_root,
            remote_storage_subdir=remote_storage_subdir,
            force=force,
            on_event=_record,
        )
        state["result"] = result
        state["phase"] = "done" if result.get("ok") else "failed"
        if not result.get("ok"):
            state["error"] = {
                "message": f"sync_to_db.py exited {result.get('exit_code')}",
                "body": (result.get("stderr") or "")[:2000],
            }
        else:
            # Book successfully pushed to VM — persist the flag locally so
            # the studio sidebar can show a green tick on next open without
            # any DB query.
            from datetime import datetime, timezone
            _manifest = persist.read_manifest(slug) or {}
            _manifest["vm_upload_done"] = True
            _manifest["vm_upload_done_utc"] = datetime.now(timezone.utc).isoformat()
            persist.write_manifest(slug, _manifest)
    except vm_publish.VmPublishError as exc:
        state["error"] = {"message": str(exc), "stage": exc.stage, "body": exc.body}
        state["phase"] = "failed"
    except Exception as exc:  # noqa: BLE001
        state["error"] = {"message": repr(exc)}
        state["phase"] = "failed"


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
