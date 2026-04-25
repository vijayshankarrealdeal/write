from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class UserResponse(BaseModel):
    id: UUID
    email: str
    name: str | None
    photo_url: str | None
    onboarding_complete: bool
    onboarding_data: dict | None
    likes: list[str]
    reading_list: list[str]
    saved_posts: list[str]
    favorite_posts: list[str]
    section_bookmarks: list[str]
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class UserUpdate(BaseModel):
    name: str | None = None
    photo_url: str | None = None
    onboarding_complete: bool | None = None
    onboarding_data: dict | None = None


class ListUpdateRequest(BaseModel):
    """For adding/removing items from user lists (likes, saved_posts, etc.)."""
    action: str  # "add" or "remove"
    item_id: str
