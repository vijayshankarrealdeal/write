from io import BytesIO

from miniopy_async import Minio

from app.config import settings

minio_client = Minio(
    settings.minio_endpoint,
    access_key=settings.minio_access_key,
    secret_key=settings.minio_secret_key,
    secure=settings.minio_use_ssl,
)


async def upload_file(path: str, data: bytes, content_type: str = "image/jpeg") -> str:
    """Upload bytes to MinIO and return the public URL."""
    await minio_client.put_object(
        settings.minio_bucket,
        path,
        BytesIO(data),
        length=len(data),
        content_type=content_type,
    )
    return f"{settings.minio_public_url}/{settings.minio_bucket}/{path}"
