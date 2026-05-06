from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field


class AuthorBookmarkCreate(BaseModel):
    """Idempotent create — if the same (user, section_id, offset) tuple
    already exists, the server returns the existing row rather than 409.
    Mirrors the reader-side ``BookmarkCreate`` so the outbox replays an
    upsert without leaving duplicates if the previous response was lost
    in flight.
    """

    writing_id: UUID
    section_id: str = Field(min_length=1, max_length=64)
    offset: int = Field(ge=0)
    label: str | None = None
    color: str = "#FFB300"
    client_op_id: str | None = None


class AuthorBookmarkPatch(BaseModel):
    """Editable fields. ``offset`` IS patchable — the client adjusts it
    locally via Quill delta math whenever text is inserted/deleted before
    the marker, then flushes the new value through the outbox. Unlike
    reader bookmarks, the dedupe constraint here lives on (user, section,
    offset) and the server simply takes the client's recomputed offset
    as truth.
    """

    label: str | None = None
    color: str | None = None
    offset: int | None = Field(default=None, ge=0)


class AuthorBookmarkResponse(BaseModel):
    id: UUID
    user_id: UUID
    writing_id: UUID
    section_id: str
    offset: int
    label: str | None
    color: str
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}
