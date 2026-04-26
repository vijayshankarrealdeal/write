from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class FeedItemCreate(BaseModel):
    title: str
    description: str | None = None
    image_url: str | None = None
    image_meta: dict | None = None
    genres: list[str] = []
    writing_types: list[str] = []
    tags: list[str] = []
    is_draft: bool = True
    sections: list[dict] | None = None


class FeedItemUpdate(BaseModel):
    title: str | None = None
    description: str | None = None
    image_url: str | None = None
    image_meta: dict | None = None
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
    image_meta: dict | None = None
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


class FacetEntry(BaseModel):
    """One bucket in the facet sidebar — a (label, count) pair."""

    value: str
    count: int


class FacetResponse(BaseModel):
    """Top genres / tags / writing_types served by `/api/feed/facets`."""

    genres: list[FacetEntry]
    tags: list[FacetEntry]
    writing_types: list[FacetEntry]


class CommentCreate(BaseModel):
    text: str
    rating: float | None = None


class CommentResponse(BaseModel):
    id: UUID
    feed_item_id: UUID
    author_id: UUID
    author_name: str | None
    author_photo_url: str | None
    author_photo_meta: dict | None = None
    text: str
    rating: float | None
    created_at: datetime

    model_config = {"from_attributes": True}
