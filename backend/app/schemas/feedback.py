from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field, field_validator

from app.models.feedback import FEEDBACK_CATEGORIES, FEEDBACK_STATUSES


class FeedbackCreate(BaseModel):
    message: str = Field(min_length=1, max_length=4000)
    category: str = "other"
    platform: str | None = Field(default=None, max_length=16)
    app_version: str | None = Field(default=None, max_length=32)

    @field_validator("category")
    @classmethod
    def _check_category(cls, v: str) -> str:
        if v not in FEEDBACK_CATEGORIES:
            raise ValueError(f"category must be one of {FEEDBACK_CATEGORIES}")
        return v


class FeedbackUpdate(BaseModel):
    status: str

    @field_validator("status")
    @classmethod
    def _check_status(cls, v: str) -> str:
        if v not in FEEDBACK_STATUSES:
            raise ValueError(f"status must be one of {FEEDBACK_STATUSES}")
        return v


class FeedbackResponse(BaseModel):
    id: UUID
    user_id: UUID | None
    user_name: str | None = None
    user_email: str | None = None
    category: str
    message: str
    platform: str | None
    app_version: str | None
    status: str
    resolver_id: UUID | None
    resolved_at: datetime | None
    created_at: datetime

    model_config = {"from_attributes": True}
