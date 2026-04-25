from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class ReadingProgressUpdate(BaseModel):
    scroll_position: float | None = None
    completed: bool | None = None


class ReadingProgressResponse(BaseModel):
    id: UUID
    user_id: UUID
    feed_item_id: UUID
    scroll_position: float | None
    last_read_at: datetime | None
    completed: bool
    created_at: datetime | None = None

    model_config = {"from_attributes": True}
