"""Pydantic schemas for the book-character cast strip.

A `BookCharacter` row carries a name, a one-line appearance the scout
proposed, and (for books illustrated by the ingest pipeline) a portrait
URL + image_meta. The endpoint returns a flat list ordered by
`sort_order` so the client can render the cast strip in the order the
scout intended (protagonist first).
"""
from __future__ import annotations

from uuid import UUID

from pydantic import BaseModel


class BookCharacterRead(BaseModel):
    id: UUID
    name: str
    appearance: str
    image_url: str | None = None
    image_meta: dict | None = None
    sort_order: int = 0

    class Config:
        from_attributes = True
