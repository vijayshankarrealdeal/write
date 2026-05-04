from __future__ import annotations

from pydantic import BaseModel, Field


class SubmitWordRequest(BaseModel):
    word: str = Field(min_length=2, max_length=64)
    language: str = Field(default="en", min_length=2, max_length=8)


class SubmitWordResponse(BaseModel):
    status: str  # 'queued' | 'duplicate' | 'already_global'


class SnapshotResponse(BaseModel):
    """Delta-only response.

    ``added`` and ``removed`` are empty when the client is already at
    ``version`` — the wire payload for an up-to-date client is one
    integer plus two empty arrays.
    """

    version: int
    added: list[str]
    removed: list[str]
