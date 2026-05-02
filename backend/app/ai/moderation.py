"""AI moderation for chat (and other free-form text).

A single LLM call returns a small, strictly-typed JSON verdict —
flagged + per-category booleans + a 0..1 severity score. We use the
chat deployment (not the OpenAI moderation endpoint, which Azure
exposes inconsistently) so we always have a configured model. When
AI is not configured the helper degrades to a passthrough — better
than blocking chat in dev.

Categories mirror Play policy buckets so a "flagged" verdict can be
mapped directly into a `Report.reason` value with no translation.
"""
from __future__ import annotations

import json
from typing import Any

from app.ai.client import ai_configured, chat_client
from app.config import settings
from app.logger import get_logger

log = get_logger("app.ai.moderation")


CATEGORY_TO_REASON = {
    "harassment": "harassment",
    "hate": "hate",
    "sexual": "sexual",
    "violence": "violence",
    "self_harm": "self_harm",
    "spam": "spam",
}


_SYSTEM_PROMPT = (
    "You are a strict but fair content moderator for a one-on-one messaging "
    "feature in a reading/writing app. Classify the user's message across "
    "these categories: harassment, hate, sexual, violence, self_harm, spam. "
    "Return ONLY a single JSON object — no prose, no markdown — with the "
    "exact shape: "
    '{"flagged": bool, "categories": {"harassment": bool, "hate": bool, '
    '"sexual": bool, "violence": bool, "self_harm": bool, "spam": bool}, '
    '"severity": float, "reason": string}. '
    "severity is 0..1. Set flagged=true only when at least one category is "
    "true and severity >= 0.6. Quoted literature, fiction, and discussion "
    "of dark themes in a writing context should NOT be flagged unless they "
    "directly target another user or contain explicit threats / sexual "
    "content involving minors / direct slurs."
)


_EMPTY: dict[str, Any] = {
    "flagged": False,
    "categories": {k: False for k in ("harassment", "hate", "sexual", "violence", "self_harm", "spam")},
    "severity": 0.0,
    "reason": "",
    "model": None,
}


async def moderate_text(text: str) -> dict[str, Any]:
    """Return a moderation verdict. Never raises — failures degrade to
    "not flagged" so a misbehaving moderator can't take down chat."""
    if not text or not text.strip():
        return _EMPTY
    if not ai_configured():
        return _EMPTY

    try:
        resp = await chat_client.chat.completions.create(
            model=settings.azure_openai_chat_deployment,
            messages=[
                {"role": "system", "content": _SYSTEM_PROMPT},
                {"role": "user", "content": text[:4000]},
            ],
            temperature=0,
            max_completion_tokens=200,
            response_format={"type": "json_object"},
        )
        raw = (resp.choices[0].message.content or "").strip()
        data = json.loads(raw)
        cats = data.get("categories") or {}
        return {
            "flagged": bool(data.get("flagged", False)),
            "categories": {k: bool(cats.get(k, False)) for k in CATEGORY_TO_REASON},
            "severity": float(data.get("severity", 0.0) or 0.0),
            "reason": str(data.get("reason", ""))[:500],
            "model": settings.azure_openai_chat_deployment,
        }
    except Exception as exc:
        log.warning("moderate_text failed, fail-open: %s", exc)
        return _EMPTY


def primary_reason(verdict: dict[str, Any]) -> str:
    """Pick the highest-priority category that fired. Falls back to
    'other' so a flagged-but-unspecified verdict still maps cleanly."""
    cats = verdict.get("categories") or {}
    # Order = severity priority. self_harm and sexual outrank spam.
    for key in ("self_harm", "sexual", "violence", "hate", "harassment", "spam"):
        if cats.get(key):
            return CATEGORY_TO_REASON[key]
    return "other"
