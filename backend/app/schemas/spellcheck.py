from pydantic import BaseModel, Field


class SpellCheckRequest(BaseModel):
    text: str = Field(default="", max_length=200_000)
    ignored: list[str] = Field(default_factory=list, max_length=5_000)


class Misspelling(BaseModel):
    word: str
    start: int
    length: int


class SpellCheckResponse(BaseModel):
    issues: list[Misspelling]


class SuggestRequest(BaseModel):
    word: str = Field(min_length=1, max_length=64)
    max: int = Field(default=5, ge=1, le=20)


class SuggestResponse(BaseModel):
    suggestions: list[str]
