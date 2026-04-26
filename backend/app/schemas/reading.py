from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class ReadingProgressUpdate(BaseModel):
    scroll_position: float | None = None
    completed: bool | None = None
    last_section_id: str | None = None
    last_anchor: dict | None = None


class ReadingProgressResponse(BaseModel):
    id: UUID
    user_id: UUID
    feed_item_id: UUID
    scroll_position: float | None
    last_read_at: datetime | None
    completed: bool
    last_section_id: str | None = None
    last_anchor: dict | None = None
    created_at: datetime | None = None

    model_config = {"from_attributes": True}


class ContinueReadingItem(BaseModel):
    """Joined view used by the home rail — feed item metadata + the user's
    last position. Image/title come straight from `feed_items` so the rail
    can render without an extra round trip."""

    feed_item_id: UUID
    title: str | None
    author: str | None
    image_url: str | None
    image_meta: dict | None = None
    scroll_position: float | None
    last_read_at: datetime | None
    last_section_id: str | None = None
    last_anchor: dict | None = None
    completed: bool

    model_config = {"from_attributes": True}
