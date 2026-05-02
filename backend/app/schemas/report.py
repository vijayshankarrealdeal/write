from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field, field_validator

from app.models.report import REPORT_REASONS, REPORT_STATUSES, TARGET_TYPES


class ReportCreate(BaseModel):
    target_type: str
    target_id: str
    reason: str
    note: str | None = Field(default=None, max_length=2000)

    @field_validator("target_type")
    @classmethod
    def _check_target_type(cls, v: str) -> str:
        if v not in TARGET_TYPES:
            raise ValueError(f"target_type must be one of {TARGET_TYPES}")
        return v

    @field_validator("reason")
    @classmethod
    def _check_reason(cls, v: str) -> str:
        if v not in REPORT_REASONS:
            raise ValueError(f"reason must be one of {REPORT_REASONS}")
        return v


class ReportUpdate(BaseModel):
    status: str

    @field_validator("status")
    @classmethod
    def _check_status(cls, v: str) -> str:
        if v not in REPORT_STATUSES:
            raise ValueError(f"status must be one of {REPORT_STATUSES}")
        return v


class ReportResponse(BaseModel):
    id: UUID
    reporter_id: UUID | None
    reporter_name: str | None = None
    target_type: str
    target_id: str
    target_author_id: UUID | None
    target_author_name: str | None = None
    reason: str
    note: str | None
    snapshot: str | None
    ai_meta: dict | None
    source: str
    status: str
    resolver_id: UUID | None
    resolved_at: datetime | None
    created_at: datetime

    model_config = {"from_attributes": True}
