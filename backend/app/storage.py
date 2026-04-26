import asyncio
from io import BytesIO

from miniopy_async import Minio

from app.config import settings
from app.image_pipeline import ProcessedVariant

minio_client = Minio(
    settings.minio_endpoint,
    access_key=settings.minio_access_key,
    secret_key=settings.minio_secret_key,
    secure=settings.minio_use_ssl,
)


_CONTENT_TYPES = {
    "webp": "image/webp",
    "jpeg": "image/jpeg",
    "jpg": "image/jpeg",
    "png": "image/png",
}

# 1 year, immutable. Variant URLs include a path version (covers) or are
# identity-by-key (avatars), so the bytes at a URL never change without a
# new URL. Browsers + intermediaries can cache forever.
_IMMUTABLE_CACHE = "public, max-age=31536000, immutable"


def _public_url(path: str) -> str:
    return f"{settings.minio_public_url}/{settings.minio_bucket}/{path}"


async def upload_file(path: str, data: bytes, content_type: str = "image/jpeg") -> str:
    """Upload bytes to MinIO and return the public URL."""
    await minio_client.put_object(
        settings.minio_bucket,
        path,
        BytesIO(data),
        length=len(data),
        content_type=content_type,
    )
    return _public_url(path)


async def upload_variants(
    base_path: str,
    variants: list[ProcessedVariant],
) -> str:
    """Upload all processed variants under `base_path/{key}.{fmt}` in parallel.

    Returns the public base URL (no extension) so callers can build per-variant
    URLs as `{base}/{key}.{fmt}`.

    Each object is tagged with `Cache-Control: immutable` so the CDN/browser
    layer can cache it for a year. Safe because the URL identity changes
    (cover paths are versioned, avatar paths re-upload identically and the
    bytes are equivalent at q=82 WebP).
    """
    async def _put(v: ProcessedVariant) -> None:
        path = f"{base_path}/{v.key}.{v.fmt}"
        await minio_client.put_object(
            settings.minio_bucket,
            path,
            BytesIO(v.data),
            length=len(v.data),
            content_type=_CONTENT_TYPES.get(v.fmt, "application/octet-stream"),
            metadata={"Cache-Control": _IMMUTABLE_CACHE},
        )

    await asyncio.gather(*(_put(v) for v in variants))
    return _public_url(base_path)


async def delete_prefix(prefix: str) -> int:
    """Delete every object under `prefix/`. Returns the count removed.

    Used to garbage-collect prior cover-version variant sets when a user
    replaces a cover. MinIO has no filesystem semantics — "directory delete"
    is "list + remove each object".
    """
    count = 0
    # `recursive=True` walks into nested keys under the prefix.
    async for obj in minio_client.list_objects(
        settings.minio_bucket, prefix=prefix, recursive=True
    ):
        await minio_client.remove_object(settings.minio_bucket, obj.object_name)
        count += 1
    return count
