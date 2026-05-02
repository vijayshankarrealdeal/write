"""Batch driver — run the full ingest+sync pipeline over a folder of books.

Designed for the Gutenberg-selected dataset: point this at a folder of
`.html` (or mixed `.html`/`.pdf`) files and it processes each one end to
end:

    1. ingest_book.py  →  filesystem artifacts + bundle.zip
    2. sync_to_db.py   →  MinIO uploads + Postgres rows under inkspace

Per-book failures are isolated (logged, batch keeps going). State is
written to `storage/batch_state.json` so a restart skips books already
synced. Use `--retry-failed` to re-attempt only books that errored on a
prior run.

Examples:

    # Process every .html in the data folder, end-to-end.
    python batch_ingest.py data/gutenberg-selected/

    # Just the first 5 (sanity check before unleashing the full batch).
    python batch_ingest.py data/gutenberg-selected/ --limit 5

    # Ingest only — write artifacts to disk, skip the DB/MinIO sync.
    python batch_ingest.py data/gutenberg-selected/ --no-sync

    # Re-attempt the books that failed on a previous batch run.
    python batch_ingest.py data/gutenberg-selected/ --retry-failed

    # Skip Frankenstein (already synced) and start at the next book.
    python batch_ingest.py data/gutenberg-selected/ --start-after frankenstein

Cost-aware: prints a running estimate so you can pause if it diverges
from expectations.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import sys
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent
_BACKEND_ROOT = _HERE.parent
if str(_BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(_BACKEND_ROOT))

from book_ingest import persist  # noqa: E402
from book_ingest.pipeline import ingest_pdf  # noqa: E402

# Rough per-book cost estimate (USD) for a Frankenstein-sized book on
# the current Azure rate card. Surfaced so the operator can sanity-check
# before kicking off the full 99.
_EST_COST_PER_BOOK = 1.0

_STATE_PATH = _HERE / "storage" / "batch_state.json"


def _slug_from_filename(path: Path) -> str:
    stem = re.sub(r"^\d+_", "", path.stem)
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", stem.lower()).strip("-")
    return slug or "book"


def _load_state() -> dict[str, Any]:
    if _STATE_PATH.exists():
        try:
            return json.loads(_STATE_PATH.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return {"books": {}}
    return {"books": {}}


def _save_state(state: dict[str, Any]) -> None:
    _STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    _STATE_PATH.write_text(json.dumps(state, indent=2), encoding="utf-8")


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Batch-ingest every book in a folder end-to-end.",
    )
    p.add_argument("folder", help="Folder of .html / .pdf files.")
    p.add_argument("--limit", type=int, default=None,
                   help="Stop after N books (handy for sanity checks).")
    p.add_argument("--start-after", default=None,
                   help="Skip every book whose slug sorts <= this. "
                        "Useful for resuming from a known point.")
    p.add_argument("--only", default=None,
                   help="Run only books whose slug contains this substring.")
    p.add_argument("--retry-failed", action="store_true",
                   help="Only re-attempt books recorded as failed in batch_state.json.")
    p.add_argument("--no-sync", action="store_true",
                   help="Run ingest only (filesystem artifacts + bundle); "
                        "skip DB/MinIO sync.")
    p.add_argument("--dry-run", action="store_true",
                   help="Show the plan (slugs, order) and exit without "
                        "running anything.")
    p.add_argument("--ext", default=".html,.htm,.pdf",
                   help="Comma-separated extensions to process.")
    return p.parse_args()


def _discover(folder: Path, exts: tuple[str, ...]) -> list[Path]:
    paths = [p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in exts]
    paths.sort(key=lambda p: p.name.lower())
    return paths


def _already_synced_via_manifest(slug: str) -> bool:
    """Skip books that were synced manually (e.g. via sync_to_db.py)
    before this batch run started. The per-book manifest is the source
    of truth for that — batch_state.json only knows about books we
    processed in a previous batch run."""
    manifest = persist.read_manifest(slug)
    return bool(manifest and manifest.get("synced"))


def _filter_books(
    paths: list[Path],
    *,
    start_after: str | None,
    only: str | None,
    state: dict[str, Any],
    retry_failed: bool,
    limit: int | None,
) -> list[Path]:
    out: list[Path] = []
    for path in paths:
        slug = _slug_from_filename(path)
        if start_after and slug <= start_after:
            continue
        if only and only.lower() not in slug:
            continue
        record = state["books"].get(slug, {})
        status = record.get("status")
        if retry_failed:
            if status != "failed":
                continue
        else:
            if status == "synced" or _already_synced_via_manifest(slug):
                continue
        out.append(path)
        if limit is not None and len(out) >= limit:
            break
    return out


async def _run_one(
    path: Path,
    *,
    no_sync: bool,
    state: dict[str, Any],
) -> tuple[str, str]:
    """Run ingest (and optionally sync) for one book. Returns (slug, status).

    status ∈ {'synced','ingested','failed','skipped-already-synced'}.
    """
    slug = _slug_from_filename(path)
    record = state["books"].setdefault(slug, {})
    record["source_file"] = str(path)
    record["last_attempt_utc"] = datetime.now(timezone.utc).isoformat()

    print(f"\n{'=' * 78}")
    print(f"[{slug}] starting")
    print(f"  source: {path.name}")

    t_start = time.monotonic()
    try:
        result = await ingest_pdf(
            pdf_path=str(path),
            slug=slug,
            # title=None — let the loader + title_cleaner pick the title.
        )
    except Exception as exc:  # noqa: BLE001
        record["status"] = "failed"
        record["phase_failed"] = "ingest"
        record["error"] = f"{type(exc).__name__}: {exc}"
        record["traceback"] = traceback.format_exc()[-2000:]
        _save_state(state)
        print(f"[{slug}] INGEST FAILED: {type(exc).__name__}: {exc}")
        return slug, "failed"

    record["ingest_seconds"] = round(time.monotonic() - t_start, 1)
    record["chunks"] = result.n_chunks
    record["images"] = result.n_images
    record["book_dir"] = result.book_dir

    if no_sync:
        record["status"] = "ingested"
        _save_state(state)
        print(f"[{slug}] ingested only (no-sync mode). "
              f"{result.n_chunks} chunks, {result.n_images} images.")
        return slug, "ingested"

    # Sync — delegate to sync_to_db's flow programmatically.
    print(f"[{slug}] ingested. starting DB+MinIO sync…")
    t_sync = time.monotonic()
    try:
        from sync_to_db import _build_cleaned_markdown_map, _load_artifacts, _pick_cover, _upload_images  # noqa: E402
        from book_ingest import db_publish  # noqa: E402

        manifest = persist.read_manifest(slug)
        if not manifest:
            raise RuntimeError("manifest missing post-ingest — pipeline bug?")

        chunks, briefs, deeps, scenes_by_chunk_local = _load_artifacts(slug)
        if not chunks:
            raise RuntimeError("no chunks on disk after ingest")

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

        # Build description: poster's back-cover copy first, fall back to
        # the original subtitle so the detail page still has a hook.
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
    except Exception as exc:  # noqa: BLE001
        record["status"] = "failed"
        record["phase_failed"] = "sync"
        record["error"] = f"{type(exc).__name__}: {exc}"
        record["traceback"] = traceback.format_exc()[-2000:]
        _save_state(state)
        print(f"[{slug}] SYNC FAILED: {type(exc).__name__}: {exc}")
        return slug, "failed"

    record["sync_seconds"] = round(time.monotonic() - t_sync, 1)
    record["total_seconds"] = round(time.monotonic() - t_start, 1)
    record["synced"] = db_ids
    record["status"] = "synced"
    record.pop("error", None)
    record.pop("traceback", None)
    record.pop("phase_failed", None)
    _save_state(state)
    print(f"[{slug}] SYNCED. writing_id={db_ids['writing_id']} "
          f"({record['total_seconds']:.0f}s)")
    return slug, "synced"


async def _main() -> int:
    args = _parse_args()
    folder = Path(args.folder).resolve()
    if not folder.is_dir():
        print(f"Not a folder: {folder}", file=sys.stderr)
        return 2

    exts = tuple(e.strip().lower() for e in args.ext.split(",") if e.strip())
    state = _load_state()

    all_paths = _discover(folder, exts)
    queue = _filter_books(
        all_paths,
        start_after=args.start_after,
        only=args.only,
        state=state,
        retry_failed=args.retry_failed,
        limit=args.limit,
    )

    print(f"discovered: {len(all_paths)} files in {folder}")
    print(f"to process: {len(queue)}")
    if args.retry_failed:
        print("mode: retry-failed (skipping anything not already marked failed)")
    if not queue:
        print("nothing to do — every book in scope already synced.")
        return 0

    est_cost = len(queue) * _EST_COST_PER_BOOK
    print(f"estimated cost: ~${est_cost:.0f} "
          f"({len(queue)} books × ~${_EST_COST_PER_BOOK:.2f}/book)")

    if args.dry_run:
        print()
        print("dry-run plan:")
        for p in queue:
            print(f"  {_slug_from_filename(p):50s}  ←  {p.name}")
        return 0

    counts = {"synced": 0, "ingested": 0, "failed": 0}
    t0 = time.monotonic()
    for i, path in enumerate(queue, start=1):
        print(f"\n[batch] {i}/{len(queue)}  ({(i - 1) / len(queue) * 100:.0f}% done)")
        slug, status = await _run_one(path, no_sync=args.no_sync, state=state)
        counts[status] = counts.get(status, 0) + 1
        elapsed = time.monotonic() - t0
        avg = elapsed / i if i else 0
        eta_s = avg * (len(queue) - i)
        print(f"[batch] running totals: synced={counts['synced']} "
              f"ingested-only={counts['ingested']} failed={counts['failed']}  |  "
              f"elapsed {elapsed / 60:.1f}m, eta {eta_s / 60:.1f}m")

    print()
    print(f"=== batch complete in {(time.monotonic() - t0) / 60:.1f}m ===")
    print(f"  synced:        {counts['synced']}")
    print(f"  ingested-only: {counts['ingested']}")
    print(f"  failed:        {counts['failed']}")
    if counts["failed"]:
        failed_slugs = [
            slug for slug, rec in state["books"].items()
            if rec.get("status") == "failed"
        ]
        print(f"  failed slugs:  {failed_slugs}")
        print(f"  retry: python batch_ingest.py {folder} --retry-failed")
    return 0 if counts["failed"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
