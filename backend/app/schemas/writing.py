from datetime import datetime
from typing import Any
from uuid import UUID

from pydantic import BaseModel


class WritingCreate(BaseModel):
    title: str | None = None
    description: str | None = None
    cover_image_path: str | None = None
    cover_image_meta: dict | None = None
    status: str | None = None
    writing_type: str | None = None
    subtype: str | None = None
    target_word_count: int | None = None
    target_deadline: datetime | None = None
    label_meaning: str | None = None
    label_names: dict | None = None


class WritingUpdate(BaseModel):
    title: str | None = None
    description: str | None = None
    cover_image_path: str | None = None
    cover_image_meta: dict | None = None
    status: str | None = None
    writing_type: str | None = None
    subtype: str | None = None
    section_ids: list[str] | None = None
    target_word_count: int | None = None
    target_deadline: datetime | None = None
    label_meaning: str | None = None
    label_names: dict | None = None


class WritingResponse(BaseModel):
    id: UUID
    user_id: UUID
    title: str | None
    author: str | None
    description: str | None
    cover_image_path: str | None
    cover_image_meta: dict | None = None
    status: str | None
    writing_type: str | None
    subtype: str | None
    section_ids: list[str]
    target_word_count: int | None = None
    target_deadline: datetime | None = None
    label_meaning: str | None = None
    label_names: dict | None = None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class SectionCreate(BaseModel):
    title: str | None = None
    # Quill deltas are JSON arrays (not dicts), and canvas data may be either —
    # accept anything JSON-serializable; the column is JSONB.
    content: Any | None = None
    canvas_data: Any | None = None
    section_color: int | None = None
    parent_id: str | None = None
    sort_order: int | None = None
    kind: str | None = None
    synopsis: str | None = None
    notes: Any | None = None
    label_color: int | None = None
    keywords: list[str] | None = None
    include_in_publish: bool | None = None


class SectionUpdate(BaseModel):
    title: str | None = None
    content: Any | None = None
    canvas_data: Any | None = None
    section_color: int | None = None
    parent_id: str | None = None
    sort_order: int | None = None
    kind: str | None = None
    synopsis: str | None = None
    notes: Any | None = None
    label_color: int | None = None
    keywords: list[str] | None = None
    include_in_publish: bool | None = None


class SectionResponse(BaseModel):
    id: UUID
    writing_id: UUID
    title: str | None
    content: Any | None
    canvas_data: Any | None
    section_color: int | None
    parent_id: str | None = None
    sort_order: int = 0
    kind: str | None = None
    synopsis: str | None = None
    notes: Any | None = None
    label_color: int | None = None
    keywords: list[str] | None = None
    include_in_publish: bool = True
    updated_at: datetime

    model_config = {"from_attributes": True}
