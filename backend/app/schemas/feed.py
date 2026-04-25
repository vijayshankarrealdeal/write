from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class FeedItemCreate(BaseModel):
    title: str
    description: str | None = None
    image_url: str | None = None
    genres: list[str] = []
    writing_types: list[str] = []
    tags: list[str] = []
    is_draft: bool = True
    sections: list[dict] | None = None


class FeedItemUpdate(BaseModel):
    title: str | None = None
    description: str | None = None
    image_url: str | None = None
    genres: list[str] | None = None
    writing_types: list[str] | None = None
    tags: list[str] | None = None
    is_draft: bool | None = None
    sections: list[dict] | None = None


class FeedItemResponse(BaseModel):
    id: UUID
    title: str | None
    author: str | None
    author_id: UUID
    description: str | None
    image_url: str | None
    genres: list[str]
    writing_types: list[str]
    tags: list[str]
    likes_count: int
    comments_count: int
    is_draft: bool
    sections: list[dict] | None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class CommentCreate(BaseModel):
    text: str
    rating: float | None = None


class CommentResponse(BaseModel):
    id: UUID
    feed_item_id: UUID
    author_id: UUID
    author_name: str | None
    author_photo_url: str | None
    text: str
    rating: float | None
    created_at: datetime

    model_config = {"from_attributes": True}
