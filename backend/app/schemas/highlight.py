from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class HighlightCreate(BaseModel):
    feed_item_id: UUID
    section_index: int
    start: int
    length: int
    color_hex: str


class HighlightResponse(BaseModel):
    id: UUID
    user_id: UUID
    feed_item_id: UUID
    section_index: int
    start: int
    length: int
    color_hex: str
    created_at: datetime

    model_config = {"from_attributes": True}
