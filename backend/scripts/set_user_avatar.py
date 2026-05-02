"""Set a user's avatar by email.

Uploads a local image to MinIO at users/<sanitized-email>/avatar.<ext>
and writes the resulting public URL into users.photo_url.

Designed to run inside the running `fastapi` container on the production
VM so DATABASE_URL and MINIO_* are already pointing at the right places.

Usage (from the production VM):

    docker compose cp ./icon.png fastapi:/tmp/avatar.png
    docker compose exec fastapi python /app/scripts/set_user_avatar.py \
        --email inkspacex@inkspacex.com \
        --avatar /tmp/avatar.png

Idempotent: rerunning overwrites the same MinIO key and rewrites photo_url.
"""

from __future__ import annotations

import argparse
import asyncio
import re
import sys
from pathlib import Path


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Set users.photo_url by email.")
    p.add_argument("--email", required=True, help="Target user's email.")
    p.add_argument("--avatar", required=True, help="Path to a local image (PNG/JPG/WebP).")
    return p.parse_args()


_EXT_TO_CT = {
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "webp": "image/webp",
}


async def _main() -> int:
    args = _parse_args()

    avatar_path = Path(args.avatar).expanduser().resolve()
    if not avatar_path.is_file():
        print(f"Avatar not found: {avatar_path}", file=sys.stderr)
        return 2

    sys.path.insert(0, "/app")

    from sqlalchemy import select
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    from app.config import settings
    from app.models.user import User
    from app.storage import upload_file

    ext = avatar_path.suffix.lstrip(".").lower() or "png"
    content_type = _EXT_TO_CT.get(ext, "application/octet-stream")
    safe_email = re.sub(r"[^a-zA-Z0-9._-]+", "_", args.email.lower())
    object_key = f"users/{safe_email}/avatar.{ext}"

    data = avatar_path.read_bytes()
    public_url = await upload_file(object_key, data, content_type=content_type)
    print(f"[minio] uploaded -> {public_url}", file=sys.stderr)

    engine = create_async_engine(settings.database_url, future=True)
    Session = async_sessionmaker(engine, expire_on_commit=False)
    async with Session() as db:
        user = (
            await db.execute(select(User).where(User.email == args.email))
        ).scalar_one_or_none()
        if user is None:
            print(f"No user with email {args.email!r}", file=sys.stderr)
            return 1
        before = user.photo_url
        user.photo_url = public_url
        await db.commit()
        print(f"[db] user_id={user.id} name={user.name!r}")
        print(f"     photo_url before: {before}")
        print(f"     photo_url after:  {public_url}")

    await engine.dispose()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
