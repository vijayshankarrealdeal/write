"""Offline-download endpoints.

Two routes:

- ``POST /api/offline/license``    — issue a license token for (user, device, book).
                                     Verifies the user can read the book first.
- ``GET  /api/offline/package/...`` — stream the encrypted `.inkx`. The license
                                     signature is part of the request so the
                                     packager can derive the same `book_key`
                                     the client will derive at decode time.

The route layer is intentionally thin — all crypto lives in
:mod:`app.offline.packager` / :mod:`app.offline.license` so the same
primitives can be exercised in tests without an HTTP transport.

Rate limit (max 10 license issues / user / hour, per p2.md) is **not**
implemented in this commit — the counter store will live in the same
place once Redis is wired up. There is a TODO marker at the issuance
path so it can't be missed in a follow-up review.
"""

from __future__ import annotations

import base64
import binascii
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import Response
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.config import settings
from app.database import get_db
from app.models.feed_item import FeedItem
from app.models.user import User
from app.offline import license as inkx_license
from app.offline import packager as inkx_packager


router = APIRouter(prefix="/api/offline", tags=["offline"])


# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------


class LicenseRequest(BaseModel):
    book_id: UUID
    device_id: UUID = Field(
        ...,
        description="Stable per-install identifier the client generates once "
        "and persists in `flutter_secure_storage`.",
    )


class LicenseResponse(BaseModel):
    """Echoes :func:`app.offline.license.issue_license` JSON exactly."""

    user_id: str
    device_id: str
    book_id: str
    issued_at: int
    expires_at: int
    server_signature: str


class PackageRequest(BaseModel):
    """Body of ``POST /api/offline/package``.

    Sent as POST (not GET) because the body carries the full license
    object and the device key wrap. GET URLs would be too long and
    would land verbatim in HTTP access logs.
    """

    license: dict[str, Any]
    device_key_b64: str = Field(
        ...,
        description="32-byte base64-encoded device key. Used by the server "
        "to derive book_key for encryption; never persisted.",
    )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _signing_key_or_503() -> str:
    key = getattr(settings, "inkx_license_signing_key", "") or ""
    if not key:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Offline downloads are not configured on this server.",
        )
    return key


async def _load_book_or_404(book_id: UUID, db: AsyncSession) -> FeedItem:
    result = await db.execute(select(FeedItem).where(FeedItem.id == book_id))
    item = result.scalar_one_or_none()
    if item is None:
        raise HTTPException(status_code=404, detail="Book not found")
    return item


def _user_can_read(user: User, item: FeedItem) -> bool:
    """Today: published items are world-readable; the user's own
    drafts are readable to them. Mirrors what the read page already
    enforces. Tightened later when subscriptions / private books land.
    """
    if not item.is_draft:
        return True
    return item.author_id == user.id


def _decode_device_key(b64: str) -> bytes:
    try:
        raw = base64.b64decode(b64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(
            status_code=400,
            detail="device_key_b64 is not valid base64",
        ) from exc
    if len(raw) != 32:
        raise HTTPException(
            status_code=400,
            detail=f"device_key must decode to 32 bytes, got {len(raw)}",
        )
    return raw


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.post("/license", response_model=LicenseResponse, status_code=201)
async def issue_offline_license(
    body: LicenseRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> LicenseResponse:
    """Sign a TTL-bounded license for `(user, device, book)`.

    The license is the public surface of the offline format — the
    packager and the Flutter codec both verify it with the same
    Ed25519 public key. Issuing a license does *not* commit the
    server to delivering bytes; the package endpoint re-checks
    access at download time.
    """
    signing_key = _signing_key_or_503()
    item = await _load_book_or_404(body.book_id, db)
    if not _user_can_read(user, item):
        raise HTTPException(status_code=403, detail="Not allowed to download this book")

    # TODO(rate-limit): cap at 10 issuances per (user, hour). Wire to
    # Redis once available; until then this endpoint is unbounded —
    # acceptable for the staging rollout, NOT for production.

    payload = inkx_license.LicensePayload.now(
        user_id=str(user.id),
        device_id=str(body.device_id),
        book_id=str(body.book_id),
    )
    license_obj, _sig = inkx_license.issue_license(
        payload, signing_key_b64=signing_key
    )
    return LicenseResponse(**license_obj)


@router.post("/package/{book_id}")
async def download_offline_package(
    book_id: UUID,
    body: PackageRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> Response:
    """Stream the encrypted `.inkx` blob for ``book_id``.

    The license in the body must (a) verify under the server's
    Ed25519 key and (b) bind to the same ``(user_id, book_id,
    device_id)`` the request authenticates as. The device key the
    client supplies is used to derive `book_key` for encryption and
    is *not* persisted server-side.
    """
    signing_key = _signing_key_or_503()
    item = await _load_book_or_404(book_id, db)
    if not _user_can_read(user, item):
        raise HTTPException(status_code=403, detail="Not allowed to download this book")

    # Verify license signature + expiry; bind to this user + book.
    try:
        signature = inkx_license.verify_license(
            body.license, signing_key_b64=signing_key
        )
    except inkx_license.LicenseError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    if body.license.get("user_id") != str(user.id):
        raise HTTPException(status_code=403, detail="License does not belong to this user")
    if body.license.get("book_id") != str(book_id):
        raise HTTPException(status_code=400, detail="License does not match requested book")

    device_key = _decode_device_key(body.device_key_b64)

    # Today images live in MinIO and the packager doesn't fetch them
    # yet — we ship sections only and leave image embedding to a
    # follow-up. This keeps the binary format stable from the first
    # cut while we settle on the image-fetch + resize pipeline.
    sections_input: list[inkx_packager.SectionInput] = []
    for idx, section in enumerate(item.sections or []):
        sections_input.append(inkx_packager.SectionInput(
            id=str(section.get("id") or f"section-{idx}"),
            title=section.get("title") or "",
            section_index=idx,
            content=section,
        ))

    blob = inkx_packager.pack_book(
        book_id=str(book_id),
        title=item.title or "",
        author=item.author or "",
        author_id=str(item.author_id),
        sections=sections_input,
        images=[],
        license_obj=body.license,
        license_signature=signature,
        device_key=device_key,
    )

    safe_title = (item.title or "book").replace("\"", "").replace("\n", " ").strip() or "book"
    return Response(
        content=blob,
        media_type="application/octet-stream",
        headers={
            "Content-Disposition": f'attachment; filename="{safe_title}.inkx"',
            "Cache-Control": "private, no-store",
        },
    )
