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
    """
    async def _put(v: ProcessedVariant) -> None:
        path = f"{base_path}/{v.key}.{v.fmt}"
        await minio_client.put_object(
            settings.minio_bucket,
            path,
            BytesIO(v.data),
            length=len(v.data),
            content_type=_CONTENT_TYPES.get(v.fmt, "application/octet-stream"),
        )

    await asyncio.gather(*(_put(v) for v in variants))
    return _public_url(base_path)
