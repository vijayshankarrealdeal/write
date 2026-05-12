"""Phase 1.6 — generate a reference portrait for every character the scout
listed in the book's `character_bible`.

Why this exists: the planner-time text-only character bible reduces drift
on macro features (clothing, age, build) but the image model still
reinterprets faces from scratch on each call, so Alice in scene 3 and
Alice in scene 19 can read as different children with the same costume.
The fix is reference-image conditioning: generate ONE canonical portrait
per character up front, then for every scene where that character
appears, pass the portrait as a reference to Azure's `/images/edits`
endpoint. The model preserves face/build while composing a new scene.

Each portrait is cached at:

    storage/books/<slug>/images/_characters/<safe_name>.png

with a matching `.json` sidecar. Files use the underscore prefix so they
sort cleanly above scene PNGs and the bundler skips them as references
rather than treating them as illustrations.

Resumable: a portrait whose PNG already exists is reused — the scout
deliberately writes the bible to the manifest so re-runs don't burn a
fresh Azure call per character.
"""

from __future__ import annotations

import asyncio
import json
import re
from pathlib import Path

from . import persist
from .config import config
from .image_gen import generate_image, size_for_composition  # noqa: F401  (size_for_composition kept for explicitness)
from .retry import with_retries


_SAFE_NAME_RE = re.compile(r"[^a-z0-9]+")


def _safe_name(name: str) -> str:
    """Turn a character name like 'Dr. Henry Jekyll' into a filesystem-safe
    'dr-henry-jekyll' for the portrait filename."""
    return _SAFE_NAME_RE.sub("-", name.lower()).strip("-") or "character"


def character_sheet_path(slug: str, name: str) -> Path:
    return persist.book_dir(slug) / "images" / "_characters" / f"{_safe_name(name)}.png"


def _portrait_prompt(name: str, appearance: str) -> str:
    """Compose the portrait prompt for a single character.

    Intentionally LOCKED to: full-body OR three-quarter view, neutral pose,
    plain background, no scene context. We want a reference that's flexible
    for any future scene — close-up, wide shot, action — not a portrait
    already committed to a setting.
    """
    return (
        f"Character reference portrait of {name}. {appearance.strip().rstrip('.')}. "
        f"Three-quarter view, head-to-knees, neutral pose, looking toward camera. "
        f"Plain warm-grey studio backdrop, even diffuse lighting, no shadows on "
        f"the background. The image is a costume + likeness reference, not a "
        f"scene illustration"
    )


async def generate_character_sheets(
    slug: str,
    *,
    bible: list[dict],
    style: str | None,
    reader_preference: str | None,
    base_palette: str | None,
) -> dict[str, str]:
    """Generate (or load from cache) one portrait per character.

    Args:
      slug: book slug.
      bible: the scout's character_bible — list of {name, appearance} dicts.
      style: book-wide art-direction string, appended to every portrait
        prompt so the references match the book's visual voice.
      reader_preference: user steering, appended same as style.
      base_palette: book-wide palette anchor, appended same way.

    Returns: {character_name: absolute_path_to_portrait_png}.
    Characters whose portrait fails generation are silently dropped from
    the returned map — downstream scenes that name them will fall back
    to text-only generation rather than block the whole book.
    """
    if not bible:
        return {}

    # Build the work list, skipping characters whose portrait already
    # exists on disk (resume).
    todo: list[dict] = []
    out: dict[str, str] = {}
    for entry in bible:
        name = entry.get("name") if isinstance(entry, dict) else None
        appearance = entry.get("appearance") if isinstance(entry, dict) else None
        if not name or not appearance:
            continue
        path = character_sheet_path(slug, name)
        if path.exists() and path.stat().st_size > 0:
            out[name] = str(path)
            continue
        todo.append({"name": name, "appearance": appearance, "path": path})

    if not todo:
        print(f"[chars] all {len(out)} character sheets cached — skipping")
        return out
    print(f"[chars] {len(out)} cached / {len(todo)} to generate "
          f"(parallel={config.image_parallelism})")

    sem = asyncio.Semaphore(config.image_parallelism)
    completed = 0
    lock = asyncio.Lock()

    async def _one(work: dict) -> tuple[str, str | None]:
        nonlocal completed
        name: str = work["name"]
        appearance: str = work["appearance"]
        out_path: Path = work["path"]
        prompt = _portrait_prompt(name, appearance)
        async with sem:
            try:
                await with_retries(
                    lambda: generate_image(
                        prompt,
                        str(out_path),
                        style=style,
                        reader_preference=reader_preference,
                        base_palette=base_palette,
                        # Portrait aspect ratio — head-to-knees needs vertical room.
                        size="1024x1536",
                        quality="medium",
                    ),
                    label=f"char[{_safe_name(name)}]",
                )
            except Exception as exc:  # noqa: BLE001
                print(f"[chars] {name!r} portrait failed: "
                      f"{type(exc).__name__}: {exc}")
                async with lock:
                    completed += 1
                return name, None
        # Write a small sidecar so downstream tooling can identify the file.
        meta = {
            "kind": "character_sheet",
            "name": name,
            "appearance": appearance,
            "prompt": prompt,
            "image_path": str(out_path),
            "model": config.image_deployment,
        }
        persist._atomic_write_text(  # type: ignore[attr-defined]
            out_path.with_suffix(".json"),
            json.dumps(meta, indent=2, ensure_ascii=False),
        )
        async with lock:
            completed += 1
            print(f"[chars] {completed}/{len(todo)}  {name!r}")
        return name, str(out_path)

    results = await asyncio.gather(*(_one(w) for w in todo))
    for name, path in results:
        if path:
            out[name] = path
    return out
