import time

from fastapi import APIRouter, Depends, HTTPException, UploadFile

from app.auth.deps import get_current_user
from app.image_pipeline import process_image
from app.models.user import User
from app.storage import upload_variants

router = APIRouter(prefix="/api/upload", tags=["upload"])

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


def _response(base_url: str, meta: dict) -> dict:
    """Build the upload response.

    - `meta`: full metadata sidecar; clients that store it pick the right
       variant per render via AppNetworkImage.
    - `url`: legacy single-URL field for clients/contexts that store only a
       URL string (Quill image embeds, canvas elements). Picks `medium` —
       balanced for inline article-body rendering — and falls back upward.
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
    return {
        "url": f"{base_url}/{chosen}.{primary_fmt}",
        "meta": meta_with_base,
    }


@router.post("/profile")
async def upload_profile_photo(
    file: UploadFile,
    user: User = Depends(get_current_user),
):
    data = await _read_image(file)
    try:
        variants, meta = await process_image(data, scope="avatar", include_original=False)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Could not decode image: {e}")
    base_path = f"users/{user.id}/profile/avatar"
    base_url = await upload_variants(base_path, variants)
    return _response(base_url, meta)


@router.post("/cover/{book_id}")
async def upload_cover_image(
    book_id: str,
    file: UploadFile,
    user: User = Depends(get_current_user),
):
    data = await _read_image(file)
    try:
        variants, meta = await process_image(data, scope="default")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Could not decode image: {e}")
    # Bust caches by versioning the path with a timestamp — covers can be
    # replaced and CDNs/clients otherwise serve the old image forever.
    version = int(time.time())
    base_path = f"users/{user.id}/covers/{book_id}/{version}"
    base_url = await upload_variants(base_path, variants)
    return _response(base_url, meta)


@router.post("/editor")
async def upload_editor_image(
    file: UploadFile,
    user: User = Depends(get_current_user),
):
    data = await _read_image(file)
    try:
        variants, meta = await process_image(data, scope="editor")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Could not decode image: {e}")
    timestamp = int(time.time() * 1000)
    base_path = f"users/{user.id}/editor/{timestamp}"
    base_url = await upload_variants(base_path, variants)
    return _response(base_url, meta)
