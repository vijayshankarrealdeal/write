from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class WritingCreate(BaseModel):
    title: str | None = None
    description: str | None = None
    cover_image_path: str | None = None
    status: str | None = None
    writing_type: str | None = None
    subtype: str | None = None


class WritingUpdate(BaseModel):
    title: str | None = None
    description: str | None = None
    cover_image_path: str | None = None
    status: str | None = None
    writing_type: str | None = None
    subtype: str | None = None
    section_ids: list[str] | None = None


class WritingResponse(BaseModel):
    id: UUID
    user_id: UUID
    title: str | None
    author: str | None
    description: str | None
    cover_image_path: str | None
    status: str | None
    writing_type: str | None
    subtype: str | None
    section_ids: list[str]
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class SectionCreate(BaseModel):
    title: str | None = None
    content: dict | None = None
    canvas_data: dict | None = None
    section_color: int | None = None


class SectionUpdate(BaseModel):
    title: str | None = None
    content: dict | None = None
    canvas_data: dict | None = None
    section_color: int | None = None


class SectionResponse(BaseModel):
    id: UUID
    writing_id: UUID
    title: str | None
    content: dict | None
    canvas_data: dict | None
    section_color: int | None
    updated_at: datetime

    model_config = {"from_attributes": True}
