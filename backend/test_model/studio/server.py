"""Studio server — slim runtime for the Inkspace reader stack.

Three jobs:
  1. Serve the reader UI (static/index.html).
  2. Serve the on-disk artifacts Claude Desktop wrote (manifest, sections,
     posters, scene / character / cover prompts, PNGs once they exist).
  3. Generate images on demand with a 5-step rephrase-and-retry loop on
     failure.

NO ingest happens here. All cleaning / chunking / map / reduce / scout /
prompt-writing is done by Claude in Claude Code, ahead of time, and lives
on disk before the server runs.
"""
from __future__ import annotations

import asyncio
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Make `book_ingest.*` importable when uvicorn loads us by package path.
_HERE = Path(__file__).resolve().parent
_ROOT = _HERE.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel

from book_ingest import inventory, persist, triage
from book_ingest.deploy import deploy_book
from book_ingest.image_gen import generate_image
from book_ingest.image_softener import soften
from book_ingest.import_main import import_all as _import_main_all


app = FastAPI(title="Inkspace Studio")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

STATIC = _HERE / "static"


# ─── Frontend ────────────────────────────────────────────────────────

@app.get("/")
async def root() -> FileResponse:
    index = STATIC / "index.html"
    if not index.exists():
        raise HTTPException(404, "index.html missing")
    return FileResponse(index)


# ─── Library ─────────────────────────────────────────────────────────

@app.get("/api/books")
async def list_books() -> list[dict[str, Any]]:
    """List every book ready for reading.

    Includes BOTH new-format books (manifest.ready_for_runtime: true)
    AND imported legacy books from the main project (they have
    artifacts on disk + an inventory entry with status=imported/ready).
    Legacy books show with `legacy_format: true` so the reader UI can
    note that chapter rendering is preview-only until Claude translates
    them to the new Delta-per-section format.
    """
    out: list[dict[str, Any]] = []
    for slug in persist.list_books():
        manifest = persist.read_json(persist.book_dir(slug) / "manifest.json") or {}
        inv_entry = inventory.lookup_by_slug(slug) or {}

        new_format_ready = bool(manifest.get("ready_for_runtime"))
        imported = inv_entry.get("imported_from") == "main"
        if not (new_format_ready or imported):
            continue

        cover = persist.read_json(persist.book_dir(slug) / "cover.json") or {}
        poster = manifest.get("poster") or (
            persist.read_json(persist.book_dir(slug) / "poster.json") or {}
        )
        # Cover status: present when the production-path PNG exists.
        book = persist.book_dir(slug)
        cover_present = (book / "images" / "cover.png").exists()
        legacy_cover_status = "ready" if cover_present else cover.get("status", "pending")
        out.append({
            "slug": slug,
            "title": manifest.get("title", slug),
            "subtitle": manifest.get("subtitle"),
            "author": manifest.get("author"),
            "description": manifest.get("description")
                or poster.get("back_cover_copy"),
            "genres": poster.get("genres", []),
            "tags": poster.get("tags", []),
            "cover_status": legacy_cover_status,
            "cover_url": f"/api/books/{slug}/cover/png",
            "legacy_format": bool(inv_entry.get("legacy_format")),
            "imported_from": inv_entry.get("imported_from"),
            "n_chunks": inv_entry.get("n_chunks"),
            "n_images": inv_entry.get("n_images"),
        })
    return out


@app.get("/api/books/{slug}")
async def get_book(slug: str) -> dict[str, Any]:
    manifest_path = persist.book_dir(slug) / "manifest.json"
    manifest = persist.read_json(manifest_path)
    if manifest is None:
        raise HTTPException(404, f"book {slug!r} not found")

    chunks_dir = persist.book_dir(slug) / "chunks"
    chunks: list[dict[str, Any]] = []
    if chunks_dir.exists():
        for cf in sorted(chunks_dir.glob("*.json")):
            data = persist.read_json(cf) or {}
            chunk_obj = data.get("chunk") or {}
            chunks.append({
                "chunk_id": chunk_obj.get("id") or cf.stem,
                "title": chunk_obj.get("chapter_title"),
                "page_start": chunk_obj.get("page_start"),
                "page_end": chunk_obj.get("page_end"),
                "scene_ids": data.get("scene_ids", []),
            })

    characters_dir = persist.book_dir(slug) / "images" / "_characters"
    cast: list[dict[str, Any]] = []
    if characters_dir.exists():
        for cf in sorted(characters_dir.glob("*.json")):
            data = persist.read_json(cf) or {}
            cast.append({
                "name_slug": cf.stem,
                "name": data.get("name", cf.stem),
                "bio": data.get("bio", ""),
                "status": data.get("status", "pending"),
                "url": f"/api/books/{slug}/characters/{cf.stem}/png",
            })

    return {
        "slug": slug,
        "manifest": manifest,
        "poster": manifest.get("poster")
            or persist.read_json(persist.book_dir(slug) / "poster.json")
            or {},
        "cover": persist.read_json(persist.book_dir(slug) / "cover.json") or {},
        "chunks": chunks,
        "cast": cast,
    }


@app.get("/api/books/{slug}/sections/{chunk_id}")
async def get_section(slug: str, chunk_id: str) -> dict[str, Any]:
    path = persist.book_dir(slug) / "sections" / f"{chunk_id}.delta.json"
    delta = persist.read_json(path)
    if delta is None:
        raise HTTPException(404, "section not found")
    if isinstance(delta, list):
        return {"chunk_id": chunk_id, "ops": delta}
    return {"chunk_id": chunk_id, "ops": delta.get("ops", delta)}


# ─── Image artifacts (read) ─────────────────────────────────────────

@app.get("/api/books/{slug}/images/{scene_id}")
async def get_scene_prompt(slug: str, scene_id: str) -> dict[str, Any]:
    payload = persist.read_json(
        persist.book_dir(slug) / "images" / f"{scene_id}.json"
    )
    if payload is None:
        raise HTTPException(404, "scene prompt not found")
    return payload


@app.get("/api/books/{slug}/images/{scene_id}/png")
async def get_scene_png(slug: str, scene_id: str) -> FileResponse:
    path = persist.book_dir(slug) / "images" / f"{scene_id}.png"
    if not path.exists():
        raise HTTPException(404, "image not generated yet")
    return FileResponse(path, media_type="image/png")


@app.get("/api/books/{slug}/characters/{name_slug}")
async def get_character_prompt(slug: str, name_slug: str) -> dict[str, Any]:
    payload = persist.read_json(
        persist.book_dir(slug) / "images" / "_characters" / f"{name_slug}.json"
    )
    if payload is None:
        raise HTTPException(404, "character prompt not found")
    return payload


@app.get("/api/books/{slug}/characters/{name_slug}/png")
async def get_character_png(slug: str, name_slug: str) -> FileResponse:
    path = persist.book_dir(slug) / "images" / "_characters" / f"{name_slug}.png"
    if not path.exists():
        raise HTTPException(404, "portrait not generated yet")
    return FileResponse(path, media_type="image/png")


@app.post("/api/books/{slug}/generate-all")
async def generate_all_images(slug: str) -> dict[str, Any]:
    """Server-side bulk image generation — called by Claude at the end
    of the prep pipeline so a book ships with every PNG already on disk,
    no human clicks needed.

    Generates in two waves:
      1. Characters first (no reference images needed) — sets up the
         character-sheet PNGs that scenes + cover will reference.
      2. Cover and scenes in parallel (now have character refs available).

    Concurrency: 5 in flight per wave. Each call uses the same
    5-strategy rephrase-retry loop as the per-image endpoint, so
    Azure content-policy hits self-recover.

    Returns success/failure counts + per-target results. The HTTP
    request blocks until everything finishes (worst-case ~5 min for
    a 40-image book), so the caller should use a generous timeout.
    """
    pending = await list_pending_images(slug)
    if pending["counts"]["total"] == 0:
        return {
            "slug": slug,
            "status": "no-op",
            "message": "all images already on disk",
            "counts": pending["counts"],
        }

    started = datetime.now(timezone.utc).isoformat()

    # ── Wave 1: characters ──────────────────────────────────────
    char_sem = asyncio.Semaphore(3)
    async def _one_char(c: dict[str, Any]) -> dict[str, Any]:
        async with char_sem:
            try:
                r = await generate_character(slug, c["name_slug"])
                return {"name_slug": c["name_slug"], "status": "ready", "attempts": r.get("attempts_taken", 1)}
            except HTTPException as exc:
                return {"name_slug": c["name_slug"], "status": "failed", "error": str(exc.detail)}
            except Exception as exc:
                return {"name_slug": c["name_slug"], "status": "failed", "error": f"{type(exc).__name__}: {exc}"}

    char_results = await asyncio.gather(*(_one_char(c) for c in pending["characters"]))

    # ── Wave 2: cover + scenes in parallel ──────────────────────
    main_sem = asyncio.Semaphore(5)

    async def _one_scene(s: dict[str, Any]) -> dict[str, Any]:
        async with main_sem:
            try:
                r = await generate_scene(slug, s["scene_id"], None)
                return {"scene_id": s["scene_id"], "status": "ready", "attempts": r.get("attempts_taken", 1)}
            except HTTPException as exc:
                return {"scene_id": s["scene_id"], "status": "failed", "error": str(exc.detail)}
            except Exception as exc:
                return {"scene_id": s["scene_id"], "status": "failed", "error": f"{type(exc).__name__}: {exc}"}

    async def _one_cover() -> dict[str, Any]:
        async with main_sem:
            try:
                r = await generate_cover(slug)
                return {"status": "ready", "attempts": r.get("attempts_taken", 1)}
            except HTTPException as exc:
                return {"status": "failed", "error": str(exc.detail)}
            except Exception as exc:
                return {"status": "failed", "error": f"{type(exc).__name__}: {exc}"}

    scene_tasks = [_one_scene(s) for s in pending["scenes"]]
    cover_task = _one_cover() if pending["cover"] else None
    if cover_task:
        scene_results, cover_result = await asyncio.gather(
            asyncio.gather(*scene_tasks),
            cover_task,
        )
    else:
        scene_results = await asyncio.gather(*scene_tasks)
        cover_result = None

    finished = datetime.now(timezone.utc).isoformat()

    def _count(items: list[dict], key: str = "status") -> int:
        return sum(1 for i in items if i.get(key) == "ready")

    char_success = _count(char_results)
    scene_success = _count(scene_results)
    cover_success = 1 if cover_result and cover_result.get("status") == "ready" else 0
    total_success = char_success + scene_success + cover_success
    total_attempted = len(char_results) + len(scene_results) + (1 if cover_result else 0)

    return {
        "slug": slug,
        "status": "complete" if total_success == total_attempted else "partial",
        "counts": {
            "total_attempted": total_attempted,
            "succeeded": total_success,
            "failed": total_attempted - total_success,
        },
        "characters": char_results,
        "scenes": scene_results,
        "cover": cover_result,
        "started_at": started,
        "completed_at": finished,
    }


@app.get("/api/books/{slug}/pending-images")
async def list_pending_images(slug: str) -> dict[str, Any]:
    """Enumerate every image artifact whose PNG is missing on disk.

    Powers the "Generate everything" button on the book detail page —
    one click, walk this list, enqueue each in the studio's JobQueue.

    For LEGACY imported books (those with PNGs already on disk under
    images/, characters/, etc., but no new-format JSON prompts), this
    returns an empty list — nothing to do. The button hides itself.
    """
    book = persist.book_dir(slug)
    if not book.is_dir():
        raise HTTPException(404, f"book {slug!r} not found")

    cover_entry: dict[str, Any] | None = None
    cover_meta = persist.read_json(book / "cover.json")
    if cover_meta:
        cover_png = book / "images" / "cover.png"
        if not cover_png.exists():
            cover_entry = {
                "status": cover_meta.get("status", "pending"),
                "size": cover_meta.get("size"),
            }

    chars: list[dict[str, Any]] = []
    portraits_dir = book / "images" / "_characters"
    if portraits_dir.exists():
        for cf in sorted(portraits_dir.glob("*.json")):
            data = persist.read_json(cf) or {}
            name_slug = cf.stem
            png = portraits_dir / f"{name_slug}.png"
            if png.exists():
                continue
            chars.append({
                "name_slug": name_slug,
                "name": data.get("name", name_slug),
                "status": data.get("status", "pending"),
            })

    scenes: list[dict[str, Any]] = []
    images_dir = book / "images"
    if images_dir.exists():
        for sf in sorted(images_dir.glob("*.json")):
            scene_id = sf.stem
            if scene_id == "cover":
                continue
            data = persist.read_json(sf) or {}
            png = images_dir / f"{scene_id}.png"
            if png.exists():
                continue
            scenes.append({
                "scene_id": scene_id,
                "chunk_id": data.get("chunk_id"),
                "status": data.get("status", "pending"),
            })

    return {
        "slug": slug,
        "cover": cover_entry,
        "characters": chars,
        "scenes": scenes,
        "counts": {
            "cover": 1 if cover_entry else 0,
            "characters": len(chars),
            "scenes": len(scenes),
            "total": (1 if cover_entry else 0) + len(chars) + len(scenes),
        },
    }


@app.get("/api/books/{slug}/cover")
async def get_cover_prompt(slug: str) -> dict[str, Any]:
    cover = persist.read_json(persist.book_dir(slug) / "cover.json")
    if cover is None:
        raise HTTPException(404, "cover prompt not found")
    return cover


@app.get("/api/books/{slug}/cover/png")
async def get_cover_png(slug: str) -> FileResponse:
    book = persist.book_dir(slug)
    path = book / "images" / "cover.png"
    if path.exists():
        return FileResponse(path, media_type="image/png")
    # Imported books may carry an absolute path in the manifest from
    # the original ingest host.
    manifest = persist.read_json(book / "manifest.json") or {}
    local = manifest.get("cover_image_local")
    if local and Path(local).exists():
        return FileResponse(local, media_type="image/png")
    raise HTTPException(404, "cover not generated yet")


# ─── Generation endpoints with rephrase-retry ──────────────────────

class GenerateBody(BaseModel):
    modification: str | None = None


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _strip_extras(prompt: str) -> str:
    """Drop palette/mood/preference extras."""
    keep: list[str] = []
    for line in prompt.split("\n"):
        s = line.strip().lower()
        if s.startswith(("palette:", "reader preference:", "mood:", "preference:")):
            continue
        keep.append(line)
    return "\n".join(keep)


def _strip_character_refs(prompt: str) -> str:
    keep: list[str] = []
    for line in prompt.split("\n"):
        if line.strip().lower().startswith("characters:"):
            continue
        keep.append(line)
    return "\n".join(keep)


def _scene_only(prompt: str) -> str:
    first = prompt.strip().split("\n")[0]
    return first + ". no text, no logos."


_STRATEGIES: list[tuple[str, Any]] = [
    ("as-is", lambda p: p),
    ("softened", soften),
    ("drop-extras", _strip_extras),
    ("drop-character-refs", _strip_character_refs),
    ("scene-only", _scene_only),
]


async def _generate_with_retries(
    prompt: str,
    *,
    size: str,
    reference_paths: list[str] | None,
    label: str,
) -> tuple[bytes, list[dict[str, Any]]]:
    """Try 5 strategies in order. Reference images are dropped at strategy
    4+ since unrecognised refs can themselves be the rejection cause.

    Returns (png_bytes, attempts_log). Raises on full exhaustion.
    """
    attempts: list[dict[str, Any]] = []
    last_exc: Exception | None = None

    for idx, (name, transform) in enumerate(_STRATEGIES, start=1):
        attempted_prompt = transform(prompt)
        refs = reference_paths if idx < 4 else None
        log_entry: dict[str, Any] = {
            "attempt": idx,
            "strategy": name,
            "prompt": attempted_prompt,
            "with_refs": bool(refs),
            "started_at": _now(),
        }
        print(f"[gen {label}] attempt {idx}/{len(_STRATEGIES)} ({name})")
        try:
            png = await generate_image(
                attempted_prompt,
                size=size,
                reference_paths=refs,
            )
            log_entry["status"] = "success"
            log_entry["completed_at"] = _now()
            attempts.append(log_entry)
            return png, attempts
        except Exception as exc:
            log_entry["status"] = "failed"
            log_entry["error"] = f"{type(exc).__name__}: {exc}"
            log_entry["completed_at"] = _now()
            attempts.append(log_entry)
            last_exc = exc
            print(f"[gen {label}] {name} failed: {exc}")

    raise RuntimeError(
        f"All {len(_STRATEGIES)} rephrase strategies exhausted for {label}: "
        f"{last_exc}"
    ) from last_exc


async def _resolve_character_refs(slug: str, refs: list[str]) -> list[str]:
    """For each `characters/<name>.json` ref, ensure its PNG exists.
    Generate it implicitly if pending. Returns list of existing PNG paths.
    """
    out: list[str] = []
    for ref in refs or []:
        name_slug = Path(ref).stem
        png = persist.book_dir(slug) / "images" / "_characters" / f"{name_slug}.png"
        if not png.exists():
            try:
                await generate_character(slug, name_slug)
            except HTTPException as exc:
                print(f"[refs {slug}/{name_slug}] skipped: {exc.detail}")
                continue
            except Exception as exc:  # noqa: BLE001
                print(f"[refs {slug}/{name_slug}] failed: {exc}")
                continue
        if png.exists():
            out.append(str(png))
    return out


@app.post("/api/books/{slug}/images/{scene_id}/generate")
async def generate_scene(
    slug: str, scene_id: str, body: GenerateBody | None = None,
) -> dict[str, Any]:
    prompt_path = persist.book_dir(slug) / "images" / f"{scene_id}.json"
    payload = persist.read_json(prompt_path)
    if payload is None:
        raise HTTPException(404, "scene prompt not found")

    ref_paths = await _resolve_character_refs(
        slug, payload.get("character_sheet_refs", []),
    )

    prompt = payload["prompt"]
    if body and body.modification:
        prompt = f"{prompt}\n\nModification: {body.modification}"

    size = payload.get("size", "1024x1536")
    png_path = persist.book_dir(slug) / "images" / f"{scene_id}.png"

    try:
        png_bytes, attempts = await _generate_with_retries(
            prompt, size=size, reference_paths=ref_paths,
            label=f"{slug}/{scene_id}",
        )
        persist.atomic_write_bytes(png_path, png_bytes)
        payload["status"] = "ready"
        payload["image_path"] = str(png_path)
        payload["generated_at"] = _now()
        payload.setdefault("attempts", []).extend(attempts)
        persist.write_json(prompt_path, payload)
        return {
            "scene_id": scene_id,
            "status": "ready",
            "url": f"/api/books/{slug}/images/{scene_id}/png",
            "attempts_taken": len(attempts),
        }
    except Exception as exc:
        payload["status"] = "failed"
        payload["last_error"] = f"{type(exc).__name__}: {exc}"
        # Attempts were already recorded inside _generate_with_retries
        # but it raised before we could collect them — pull from log.
        persist.write_json(prompt_path, payload)
        raise HTTPException(500, str(exc))


@app.post("/api/books/{slug}/characters/{name_slug}/generate")
async def generate_character(slug: str, name_slug: str) -> dict[str, Any]:
    prompt_path = persist.book_dir(slug) / "images" / "_characters" / f"{name_slug}.json"
    payload = persist.read_json(prompt_path)
    if payload is None:
        raise HTTPException(404, "character prompt not found")

    prompt = payload["prompt"]
    size = payload.get("size", "1024x1024")
    png_path = persist.book_dir(slug) / "images" / "_characters" / f"{name_slug}.png"
    png_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        png_bytes, attempts = await _generate_with_retries(
            prompt, size=size, reference_paths=None,
            label=f"{slug}/char/{name_slug}",
        )
        persist.atomic_write_bytes(png_path, png_bytes)
        payload["status"] = "ready"
        payload["image_path"] = str(png_path)
        payload["generated_at"] = _now()
        payload.setdefault("attempts", []).extend(attempts)
        persist.write_json(prompt_path, payload)
        return {
            "name_slug": name_slug,
            "status": "ready",
            "url": f"/api/books/{slug}/characters/{name_slug}/png",
            "attempts_taken": len(attempts),
        }
    except Exception as exc:
        payload["status"] = "failed"
        payload["last_error"] = f"{type(exc).__name__}: {exc}"
        persist.write_json(prompt_path, payload)
        raise HTTPException(500, str(exc))


@app.post("/api/books/{slug}/cover/generate")
async def generate_cover(slug: str) -> dict[str, Any]:
    cover_path = persist.book_dir(slug) / "cover.json"
    payload = persist.read_json(cover_path)
    if payload is None:
        raise HTTPException(404, "cover prompt not found")

    ref_paths = await _resolve_character_refs(
        slug, payload.get("character_sheet_refs", []),
    )

    prompt = payload["prompt"]
    size = payload.get("size", "1024x1536")
    png_path = persist.book_dir(slug) / "images" / "cover.png"
    png_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        png_bytes, attempts = await _generate_with_retries(
            prompt, size=size, reference_paths=ref_paths,
            label=f"{slug}/cover",
        )
        # Title overlay — composite title/subtitle/author onto the raw
        # cover. Skipped when the prompt already bakes the typography
        # into the painting (``title_overlay_baked_in: true``), which
        # the new AI-text covers use to avoid the pasted-on PIL look.
        overlay = payload.get("title_overlay") or {}
        if (
            not payload.get("title_overlay_baked_in")
            and (overlay.get("title") or overlay.get("author"))
        ):
            png_bytes = await asyncio.to_thread(
                _composite_title_overlay, png_bytes,
                title=(overlay.get("title") or "").strip(),
                subtitle=(overlay.get("subtitle") or "").strip(),
                author=(overlay.get("author") or "").strip(),
            )
        persist.atomic_write_bytes(png_path, png_bytes)
        payload["status"] = "ready"
        payload["image_path"] = str(png_path)
        payload["generated_at"] = _now()
        payload.setdefault("attempts", []).extend(attempts)
        persist.write_json(cover_path, payload)
        return {
            "slug": slug,
            "status": "ready",
            "url": f"/api/books/{slug}/cover/png",
            "attempts_taken": len(attempts),
        }
    except Exception as exc:
        payload["status"] = "failed"
        payload["last_error"] = f"{type(exc).__name__}: {exc}"
        persist.write_json(cover_path, payload)
        raise HTTPException(500, str(exc))


_OVERLAY_FONTS = (
    "/Library/Fonts/Georgia.ttf",
    "/System/Library/Fonts/Supplemental/Georgia.ttf",
    "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
    "/System/Library/Fonts/Times.ttc",
    "/System/Library/Fonts/Helvetica.ttc",
)


def _composite_title_overlay(
    png_bytes: bytes, *, title: str, subtitle: str, author: str,
) -> bytes:
    """Burn typography onto a freshly-generated cover. The model prompt
    asks for no text, so we add it ourselves with consistent placement,
    warm ivory fill, and a near-black drop shadow that reads against
    any underlying scene."""
    import io
    from PIL import Image, ImageDraw, ImageFont

    def _font(size: int) -> "ImageFont.ImageFont":
        for p in _OVERLAY_FONTS:
            if Path(p).is_file():
                try:
                    return ImageFont.truetype(p, size=size)
                except OSError:
                    continue
        return ImageFont.load_default()

    img = Image.open(io.BytesIO(png_bytes)).convert("RGB")
    W, H = img.size
    draw = ImageDraw.Draw(img)
    base = min(W, H)
    title_size = max(40, int(base * 0.058))
    sub_size = max(24, int(base * 0.034))
    author_size = max(22, int(base * 0.030))
    title_font, sub_font, author_font = _font(title_size), _font(sub_size), _font(author_size)
    margin_top = int(H * 0.055)
    margin_bottom = int(H * 0.06)
    fill = (250, 245, 230)
    shadow = (0, 0, 0, 230)

    def _draw_centered(text: str, *, y: int, font) -> None:
        bbox = draw.textbbox((0, 0), text, font=font)
        x = (W - (bbox[2] - bbox[0])) // 2
        for dx, dy in ((-2, -2), (2, -2), (-2, 2), (2, 2), (0, 3)):
            draw.text((x + dx, y + dy), text, font=font, fill=shadow)
        draw.text((x, y), text, font=font, fill=fill)

    # Title — wrap to two lines when very long.
    title_lines = [title]
    if title and draw.textbbox((0, 0), title, font=title_font)[2] > int(W * 0.86) and " " in title:
        words = title.split()
        mid = len(words) // 2
        title_lines = [" ".join(words[:mid]), " ".join(words[mid:])]
    y = margin_top
    for line in title_lines:
        if line:
            _draw_centered(line, y=y, font=title_font)
            y += int(title_size * 1.15)
    if subtitle:
        _draw_centered(subtitle, y=y + int(sub_size * 0.4), font=sub_font)
    if author:
        bbox = draw.textbbox((0, 0), author, font=author_font)
        _draw_centered(author, y=H - margin_bottom - (bbox[3] - bbox[1]), font=author_font)

    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


# ─── Inventory + triage ──────────────────────────────────────────────

@app.get("/api/inventory")
async def get_inventory(status: str | None = None) -> dict[str, Any]:
    entries = inventory.all_entries()
    if status:
        entries = [e for e in entries if e.get("status") == status]
    return {"summary": inventory.summary(), "books": entries}


@app.get("/api/triage/candidates")
async def get_triage_candidates(limit: int = 50) -> dict[str, Any]:
    return {"candidates": triage.ranked_candidates(limit=limit)}


@app.get("/api/triage/picks")
async def get_triage_picks(
    target: int = 30,
    buffer: int = 5,
    famous_floor: float = triage.FAMOUS_FLOOR,
) -> dict[str, Any]:
    """The 'pick the best N to convert' selector.

    target = how many books we want.
    buffer = max number of below-famous-floor books we'll add to top
             up if not enough famous candidates are available.
    famous_floor = triage score threshold for 'famous / well-known'.
    """
    return triage.pick_for_conversion(
        target=target, buffer=buffer, famous_floor=famous_floor,
    )


class ScanBody(BaseModel):
    folder: str | None = None  # absolute or relative to project root
    parallel: int = 8


@app.post("/api/triage/scan")
async def post_triage_scan(body: ScanBody | None = None) -> dict[str, Any]:
    folder = (body and body.folder) or "data"
    if not Path(folder).is_absolute():
        folder = str(_ROOT / folder)
    try:
        return await asyncio.to_thread(
            triage.scan_folder, folder, parallel=(body.parallel if body else 8),
        )
    except Exception as exc:
        raise HTTPException(500, str(exc))


@app.post("/api/import-from-main")
async def post_import_main() -> dict[str, Any]:
    try:
        return await asyncio.to_thread(_import_main_all)
    except Exception as exc:
        raise HTTPException(500, str(exc))


# ─── Deploy ──────────────────────────────────────────────────────────

class DeployBody(BaseModel):
    run_sync: bool = True   # also publish to Postgres+MinIO via sync_to_db.py on the VM
    force: bool = False     # republish even if manifest.synced is set


@app.post("/api/books/{slug}/deploy")
async def deploy(slug: str, body: DeployBody | None = None) -> dict[str, Any]:
    try:
        return await deploy_book(
            slug,
            run_sync=body.run_sync if body else True,
            force=body.force if body else False,
        )
    except Exception as exc:
        raise HTTPException(500, str(exc))


# ─── Health ──────────────────────────────────────────────────────────

@app.get("/api/health")
async def health() -> dict[str, Any]:
    from book_ingest.config import config as cfg
    return {
        "ok": True,
        "azure_image_endpoint_set": bool(cfg.azure_image_endpoint),
        "azure_image_key_set": bool(cfg.azure_image_api_key),
        "azure_image_deployment": cfg.azure_image_deployment,
        "ssh_deploy_configured": bool(cfg.ssh_host and cfg.ssh_user),
        "storage_root": cfg.storage_root,
        "books_on_disk": len(persist.list_books()),
    }
