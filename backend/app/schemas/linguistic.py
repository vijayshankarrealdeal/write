"""Schemas for the linguistic-focus router.

The five classes are pinned (literal Set in `_ALLOWED_CLASSES`) so a
typo in a request body comes back as a 422 rather than silently
returning empty results. Lengths cap at 200 KB of text — same ceiling
as `/api/spellcheck/check`, since they're both backed by an in-memory
parse over the document plain text.
"""
from pydantic import BaseModel, Field, field_validator


_ALLOWED_CLASSES = frozenset(
    {"dialogue", "adverbs", "adjectives", "verbs", "nouns"}
)


class LinguisticTagRequest(BaseModel):
    text: str = Field(default="", max_length=200_000)
    classes: list[str] = Field(
        default_factory=lambda: [
            "dialogue",
            "adverbs",
            "adjectives",
            "verbs",
            "nouns",
        ],
        max_length=5,
    )

    @field_validator("classes")
    @classmethod
    def _validate_classes(cls, v: list[str]) -> list[str]:
        bad = [c for c in v if c not in _ALLOWED_CLASSES]
        if bad:
            raise ValueError(
                f"unknown linguistic class(es): {bad}; allowed: "
                f"{sorted(_ALLOWED_CLASSES)}"
            )
        return v


class LinguisticSpan(BaseModel):
    start: int
    length: int


class LinguisticTagResponse(BaseModel):
    dialogue: list[LinguisticSpan] = []
    adverbs: list[LinguisticSpan] = []
    adjectives: list[LinguisticSpan] = []
    verbs: list[LinguisticSpan] = []
    nouns: list[LinguisticSpan] = []
    # Set false when spaCy is unavailable on the backend so the client
    # can show a "POS tagging unavailable" hint instead of inferring
    # from empty result lists. Dialogue stays available regardless.
    pos_available: bool = True
