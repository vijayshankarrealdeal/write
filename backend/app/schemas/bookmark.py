from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field


class BookmarkAnchor(BaseModel):
    paragraph_idx: int = Field(ge=0)
    char_offset: int = Field(ge=0)


class BookmarkCreate(BaseModel):
    """Idempotent create — if the same (user, feed_item, section_index,
    anchor) tuple already exists, the server returns the existing row
    rather than 409'ing. The client therefore doesn't have to track
    server ids before enqueueing.

    `client_op_id` lets the outbox replay an upsert without leaving
    duplicates if the previous response was lost mid-flight (network
    blip after the server committed). Optional — older clients omit it.
    """

    feed_item_id: UUID
    section_id: str | None = None
    section_index: int = Field(ge=0, default=0)
    anchor: BookmarkAnchor
    label: str | None = None
    color: str = "#FFB300"
    client_op_id: str | None = None


class BookmarkPatch(BaseModel):
    """Editable fields. Anchor is intentionally NOT patchable — moving
    a bookmark = delete + create, otherwise the dedupe constraint would
    silently rebind to a stranger's row."""

    label: str | None = None
    color: str | None = None


class BookmarkResponse(BaseModel):
    id: UUID
    user_id: UUID
    feed_item_id: UUID
    section_id: str | None
    section_index: int
    anchor: dict
    label: str | None
    color: str
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}
