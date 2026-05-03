import asyncio
import time

from fastapi import APIRouter, Depends, HTTPException, UploadFile
from PIL import Image as PILImage

from app.auth.deps import get_current_user
from app.image_pipeline import process_image
from app.logger import get_logger
from app.models.user import User
from app.storage import upload_variants

router = APIRouter(prefix="/api/upload", tags=["upload"])
log = get_logger("app.upload")

# Bytes accepted before processing. Pillow can blow up RAM on adversarial
# inputs, so reject early — 15MB covers a 12MP phone JPEG with headroom.
MAX_SIZE = 15 * 1024 * 1024
ALLOWED_PREFIXES = ("image/",)


async def _read_image(file: UploadFile) -> bytes:
    if file.content_type and not file.content_type.startswith(ALLOWED_PREFIXES):
        raise HTTPException(status_code=415, detail="Only image uploads are accepted")
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty upload")
    if len(data) > MAX_SIZE:
        raise HTTPException(status_code=413, detail="File too large (max 15MB)")
    return data


async def _safe_process(data: bytes, **kwargs):
    """Wrap `process_image` and translate Pillow's failure modes into HTTP."""
    try:
        return await process_image(data, **kwargs)
    except PILImage.DecompressionBombError:
        # Bomb threshold tripped — likely an attack or a genuinely huge upload
        # that we won't decode. 413 says "your file is bigger than we'll handle"
        # which is true regardless of whether it was malicious.
        raise HTTPException(status_code=413, detail="Image too large to decode")
    except PILImage.UnidentifiedImageError:
        raise HTTPException(status_code=415, detail="Unsupported image format")
    except Exception as e:
        log.warning("Image decode failed: %s", e)
        raise HTTPException(status_code=400, detail="Could not decode image")


def _response(base_url: str, meta: dict, *, scope: str = "default") -> dict:
    """Build the upload response.

    - `meta`: full metadata sidecar; clients that store it pick the right
       variant per render via AppNetworkImage.
    - `url`: legacy single-URL field for clients/contexts that store only a
       URL string (Quill image embeds, canvas elements). Picks `medium` —
       balanced for inline article-body rendering — and falls back upward.

    For embed-only contexts (Quill inline images, canvas elements) the URL
    also carries blurhash + dimensions + scope name as a `#`-fragment so the
    client can rehydrate an `ImageMeta` even though only the string was
    persisted. The fragment uses keys `bh`, `dc`, `iw`, `ih`, `vs` —
    chosen short to keep the persisted URL compact.
    """
    variants = meta["variants"]
    primary_fmt = "webp" if "webp" in meta["formats"] else meta["formats"][0]
    # Preferred default order: medium → large → small → original → first.
    for preferred in ("medium", "large", "small", "original"):
        if preferred in variants:
            chosen = preferred
            break
    else:
        chosen = next(iter(variants))
    meta_with_base = {**meta, "base_url": base_url}
    primary_url = f"{base_url}/{chosen}.{primary_fmt}"
    fragment = (
        f"bh={meta['blurhash']}"
        f"&dc={meta['color'].lstrip('#')}"
        f"&iw={meta['width']}"
        f"&ih={meta['height']}"
        f"&vs={scope}"
    )
    return {
        "url": f"{primary_url}#{fragment}",
        "meta": meta_with_base,
    }


@router.post("/profile")
async def upload_profile_photo(
    file: UploadFile,
    user: User = Depends(get_current_user),
):
    data = await _read_image(file)
    variants, meta = await _safe_process(data, scope="avatar", include_original=False)
    # Version the path so each upload yields a new URL — otherwise CDNs and
    # the on-device image cache keep serving the previous avatar.
    version = int(time.time())
    avatar_root = f"users/{user.id}/profile/avatar"
    base_path = f"{avatar_root}/{version}"
    base_url = await upload_variants(base_path, variants)
    asyncio.create_task(_reap_old_versions(avatar_root, keep=base_path))
    return _response(base_url, meta, scope="avatar")


@router.post("/cover/{book_id}")
async def upload_cover_image(
    book_id: str,
    file: UploadFile,
    user: User = Depends(get_current_user),
):
    data = await _read_image(file)
    variants, meta = await _safe_process(data, scope="default")
    # Bust caches by versioning the path with a timestamp — covers can be
    # replaced and CDNs/clients otherwise serve the old image forever.
    version = int(time.time())
    cover_root = f"users/{user.id}/covers/{book_id}"
    base_path = f"{cover_root}/{version}"
    base_url = await upload_variants(base_path, variants)
    # Reap prior versioned variant sets so MinIO doesn't accumulate orphans
    # forever. Best-effort: if cleanup fails, the upload still succeeded — we
    # log and move on rather than fail the request the user is waiting on.
    asyncio.create_task(_reap_old_versions(cover_root, keep=base_path))
    return _response(base_url, meta, scope="default")


@router.post("/editor")
async def upload_editor_image(
    file: UploadFile,
    user: User = Depends(get_current_user),
):
    data = await _read_image(file)
    variants, meta = await _safe_process(data, scope="editor")
    timestamp = int(time.time() * 1000)
    base_path = f"users/{user.id}/editor/{timestamp}"
    base_url = await upload_variants(base_path, variants)
    return _response(base_url, meta, scope="editor")


async def _reap_old_versions(cover_root: str, *, keep: str) -> None:
    """Delete every object under `cover_root/` that isn't under `keep/`.

    Covers a few shapes:
      * Older version dirs: `cover_root/<old_version>/<variant>.webp`
      * Legacy un-versioned files from before path-versioning landed
        (e.g. avatars previously written directly to `cover_root/medium.webp`)
      * Stray objects at any other depth

    Anything that doesn't live under the current `keep/` prefix is orphaned
    by definition once the new URL is in flight, so it's safe to delete.
    """
    try:
        from app.storage import minio_client
        from app.config import settings

        keep_prefix = f"{keep}/"
        removed = 0
        async for obj in minio_client.list_objects(
            settings.minio_bucket, prefix=f"{cover_root}/", recursive=True
        ):
            if obj.object_name.startswith(keep_prefix):
                continue
            await minio_client.remove_object(settings.minio_bucket, obj.object_name)
            removed += 1
        if removed:
            log.info("Reaped %d objects under %s", removed, cover_root)
    except Exception as e:  # never let cleanup break a successful upload
        log.warning("Reap failed for %s: %s", cover_root, e)
