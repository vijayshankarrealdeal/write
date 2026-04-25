from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class BookshelfCreate(BaseModel):
    name: str
    description: str | None = None
    is_private: bool = True


class BookshelfUpdate(BaseModel):
    name: str | None = None
    description: str | None = None
    is_private: bool | None = None
    item_ids: list[str] | None = None
    cover_image_url: str | None = None


class BookshelfResponse(BaseModel):
    id: UUID
    user_id: UUID
    name: str
    description: str | None
    is_private: bool
    item_ids: list[str]
    cover_image_url: str | None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}
