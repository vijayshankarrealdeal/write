"""Spell-check API.

Backend hosts the dictionary so we can swap or grow it without shipping
new client builds. Heavy work (dictionary scan + DL suggestions) runs in
a thread executor so it never blocks the event loop.
"""
import asyncio

from fastapi import APIRouter, Depends

from app import spellcheck as engine
from app.auth.deps import get_current_user
from app.models.user import User
from app.schemas.spellcheck import (
    SpellCheckRequest,
    SpellCheckResponse,
    SuggestRequest,
    SuggestResponse,
)

router = APIRouter(prefix="/api/spellcheck", tags=["spellcheck"])


@router.post("/check", response_model=SpellCheckResponse)
async def check(
    body: SpellCheckRequest,
    _: User = Depends(get_current_user),
):
    issues = await asyncio.to_thread(engine.check, body.text, body.ignored)
    return SpellCheckResponse(issues=issues)


@router.post("/suggest", response_model=SuggestResponse)
async def suggest(
    body: SuggestRequest,
    _: User = Depends(get_current_user),
):
    suggestions = await asyncio.to_thread(engine.suggest, body.word, body.max)
    return SuggestResponse(suggestions=suggestions)
