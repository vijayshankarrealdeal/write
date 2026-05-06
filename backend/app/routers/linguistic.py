"""Linguistic Focus API.

POST `/api/linguistic/tag` returns plain-text offset spans for the
classes the editor's overlay needs (dialogue / adverbs / adjectives /
verbs / nouns). The client highlights one class at a time as a
self-editing aid.

Heavy work — spaCy parse over a multi-thousand-word section — runs
through `asyncio.to_thread` so a slow tag never blocks the event
loop. spaCy is loaded lazily on first request; when the model isn't
installed (test env, dev box without `python -m spacy download`) we
still return dialogue spans (regex-based) and flag
`pos_available=False` so the client degrades gracefully rather than
silently showing nothing.
"""
import asyncio

from fastapi import APIRouter, Depends

from app import linguistic as engine
from app.auth.deps import get_current_user
from app.models.user import User
from app.schemas.linguistic import (
    LinguisticSpan,
    LinguisticTagRequest,
    LinguisticTagResponse,
)


router = APIRouter(prefix="/api/linguistic", tags=["linguistic"])


@router.post("/tag", response_model=LinguisticTagResponse)
async def tag(
    body: LinguisticTagRequest,
    _: User = Depends(get_current_user),
):
    raw = await asyncio.to_thread(engine.tag, body.text, body.classes)
    return LinguisticTagResponse(
        dialogue=[LinguisticSpan(**s) for s in raw["dialogue"]],
        adverbs=[LinguisticSpan(**s) for s in raw["adverbs"]],
        adjectives=[LinguisticSpan(**s) for s in raw["adjectives"]],
        verbs=[LinguisticSpan(**s) for s in raw["verbs"]],
        nouns=[LinguisticSpan(**s) for s in raw["nouns"]],
        pos_available=engine.pos_available(),
    )
