"""Manual single-image regeneration.

Use this when you want to tweak one illustration without re-running the
whole 3000-page pipeline. The user picks a scene either by id (from the
images folder) or by free-text query (resolved via on-disk embeddings)
and supplies an instruction. The original prompt is preserved, the new
instruction is appended, and only that PNG is rewritten.

Examples:

    # By scene id (read it off the filename in images/)
    python regenerate_image.py bible 5b3f9a2c1e7d \\
      --instruction "darker, storm clouds, more dramatic lighting"

    # By free-text query — embeddings find the closest matching scene
    python regenerate_image.py bible \\
      --query "the storm on the sea of galilee" \\
      --instruction "dawn light breaking through clouds"

    # Show what scenes match a query without regenerating
    python regenerate_image.py bible --query "burning bush" --dry-run
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_BACKEND_ROOT = _HERE.parent
if str(_BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(_BACKEND_ROOT))

from book_ingest import embeddings, persist  # noqa: E402
from book_ingest.image_gen import compose_prompt, generate_image  # noqa: E402


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Regenerate a single illustration with new instructions.")
    p.add_argument("slug", help="Folder under storage/books/ (e.g. 'bible').")
    p.add_argument("scene_id", nargs="?", default=None,
                   help="Scene id (from images/<id>.png). Omit when using --query.")
    p.add_argument("--query", default=None,
                   help="Free-text description of the scene to regenerate. "
                        "Embeddings are used to find the closest match.")
    p.add_argument("--instruction", default=None,
                   help="What to change about the image. Appended to the original prompt.")
    p.add_argument("--top-k", type=int, default=5,
                   help="When using --query, how many candidate scenes to display.")
    p.add_argument("--dry-run", action="store_true",
                   help="Show the resolved scene + composed prompt; don't call the image API.")
    return p.parse_args()


async def _main() -> int:
    args = _parse_args()
    slug = args.slug

    book_dir = persist.book_dir(slug)
    if not (book_dir / "manifest.json").exists():
        print(f"No book at {book_dir} — has it been ingested?", file=sys.stderr)
        return 2

    scene_id = args.scene_id
    if not scene_id and args.query:
        scene_id = await _resolve_via_query(slug, args.query, args.top_k)
        if not scene_id:
            return 2
    if not scene_id:
        print("Need either a scene_id or --query.", file=sys.stderr)
        return 2

    meta = persist.read_scene_meta(slug, scene_id)
    if not meta:
        print(f"No scene meta for {scene_id}", file=sys.stderr)
        return 2

    manifest = persist.read_manifest(slug)
    style = manifest.get("style")
    reader_preference = manifest.get("reader_preference")
    original_scene_text = meta.get("scene_text", "")
    instruction = args.instruction

    composed_scene = original_scene_text
    if instruction:
        composed_scene = f"{original_scene_text}. Modification: {instruction}"

    full_prompt = compose_prompt(
        composed_scene,
        style=style,
        reader_preference=reader_preference,
    )

    print(f"\nScene:    {scene_id}")
    print(f"Original: {original_scene_text}")
    if instruction:
        print(f"Change:   {instruction}")
    print(f"\nFull prompt sent to gpt-image-2:\n{full_prompt}\n")

    if args.dry_run:
        print("[dry-run] not calling image API")
        return 0

    out_path = persist.image_path_for(slug, scene_id)
    backup = _backup_previous(out_path)
    if backup:
        print(f"[backup] previous PNG → {backup}")

    await generate_image(
        composed_scene,
        str(out_path),
        style=style,
        reader_preference=reader_preference,
    )
    print(f"[ok] wrote {out_path}")

    history = list(meta.get("revision_history") or [])
    history.append({
        "ts": datetime.now(timezone.utc).isoformat(),
        "instruction": instruction,
        "previous_prompt": meta.get("prompt"),
        "previous_backup": str(backup) if backup else None,
    })
    meta["revision_history"] = history
    meta["prompt"] = full_prompt
    meta["scene_text"] = composed_scene
    persist._atomic_write_text(  # type: ignore[attr-defined]
        persist.scene_meta_path(slug, scene_id),
        json.dumps(meta, indent=2),
    )
    return 0


async def _resolve_via_query(slug: str, query: str, top_k: int) -> str | None:
    matches = await embeddings.find_scene_by_query(slug, query, top_k=top_k)
    if not matches:
        print(f"No scene embeddings found for slug={slug}.", file=sys.stderr)
        return None

    print(f"\nTop {len(matches)} matches for: {query!r}\n")
    for i, (sid, score, text) in enumerate(matches, start=1):
        snippet = (text[:140] + "…") if len(text) > 140 else text
        print(f"  {i}. [{score:.3f}] {sid}  — {snippet}")
    print()

    if len(matches) == 1:
        chosen = matches[0][0]
        print(f"Using only match: {chosen}")
        return chosen

    answer = input("Pick number (1-N) or scene_id, blank to abort: ").strip()
    if not answer:
        return None
    if answer.isdigit() and 1 <= int(answer) <= len(matches):
        return matches[int(answer) - 1][0]
    return answer


def _backup_previous(out_path: Path) -> Path | None:
    """Save the existing PNG as <name>.<ts>.bak.png so the user can revert."""
    if not out_path.exists():
        return None
    ts = datetime.now().strftime("%Y%m%dT%H%M%S")
    backup = out_path.with_suffix(f".{ts}.bak.png")
    out_path.replace(backup)
    return backup


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
