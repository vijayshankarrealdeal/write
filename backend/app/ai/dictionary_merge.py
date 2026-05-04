"""LLM-driven noise filter for raw user dictionary submissions.

What admins see after a user spells a word and taps "Add to dictionary"
is a flood of:
- legitimate proper nouns / character names / domain terms,
- unicode-noise (emoji, accents typed by accident),
- real misspellings the user couldn't be bothered to correct.

This module bundles the pending submissions, asks the chat model to
classify each one, and returns a verdict per word. The caller
persists the verdicts and folds the accepted words into the global
dictionary.

Privacy note: only the candidate word strings are sent to the model —
no user id, no surrounding sentence, no metadata that could re-identify
who submitted them.
"""
from __future__ import annotations

import json
from dataclasses import dataclass

from app.ai.client import chat_client, ensure_ai_configured
from app.config import settings
from app.logger import get_logger

log = get_logger("app.ai.dictionary_merge")

# Conservative batch size — keeps a single completion well under the
# context window even if every word triggers a longer rationale, and
# lets a partial failure restart cheaply.
_MAX_BATCH = 200

_SYSTEM_PROMPT = """You are a lexicographer reviewing candidate words for a global English dictionary used by writers in a Wattpad-style writing app. Users tap "Add to dictionary" when their spell-checker underlines a word; you decide which of those words deserve to be made known to every other user.

Decide one verdict per word:

- "accept" — a real word, name, or term that a fluent reader would consider legitimate. Includes:
  - common proper nouns: place names, well-known people, brand/product names, fictional character archetypes (Hermione, Frodo)
  - domain-specific vocabulary: tech, medicine, sports, cuisine, literature
  - regional/colloquial words that have entered common usage (yeet, vibe, glow-up)
  - inflections and possessives missing from the base dictionary

- "reject" — a typo, gibberish, or unsafe entry. Includes:
  - clear misspellings of common words (definately, recieve, occured)
  - random keystroke noise (asdfgh, qweqweqwe)
  - profanity, slurs, sexual terms, or words that would harm other users if accepted globally
  - personal information that looks like a name + identifier (john_smith_92), email fragments, passwords
  - duplicates of existing common dictionary words (the model already knows these — accept anyway, they're harmless)

When in doubt: reject. The cost of a wasted word is one extra red underline; the cost of accepting a slur or PII is a published, globally-distributed mistake.

Respond with strict JSON only. Schema:
{"results": [{"word": "<lowercase word>", "verdict": "accept" | "reject", "note": "<short reason, max 120 chars>"}]}

Every word in the input MUST appear in the results array."""


@dataclass(frozen=True)
class WordVerdict:
    word: str
    verdict: str  # 'accept' | 'reject'
    note: str


async def classify_words(words: list[str]) -> list[WordVerdict]:
    """Classify each word as accept or reject. Returns one verdict per
    input word, in input order; missing entries fall back to reject so a
    flaky model response can never silently approve a word."""
    if not words:
        return []
    ensure_ai_configured()

    out: list[WordVerdict] = []
    # Process in batches so a single huge submission queue still
    # completes — and so a transient API blip on batch 3 doesn't lose
    # the verdicts already collected for batches 1 and 2.
    for start in range(0, len(words), _MAX_BATCH):
        batch = words[start : start + _MAX_BATCH]
        out.extend(await _classify_batch(batch))
    return out


async def _classify_batch(batch: list[str]) -> list[WordVerdict]:
    user_prompt = (
        "Candidate words (one per line):\n\n"
        + "\n".join(batch)
        + "\n\nReturn JSON now."
    )
    try:
        resp = await chat_client.chat.completions.create(
            model=settings.azure_openai_chat_deployment,
            messages=[
                {"role": "system", "content": _SYSTEM_PROMPT},
                {"role": "user", "content": user_prompt},
            ],
            response_format={"type": "json_object"},
            max_completion_tokens=8192,
        )
        raw = resp.choices[0].message.content or "{}"
        data = json.loads(raw)
        results = data.get("results") if isinstance(data, dict) else None
        if not isinstance(results, list):
            raise ValueError("model response missing 'results' array")
    except Exception as e:
        log.exception("dictionary merge classification failed: %s", e)
        # Fail closed — reject the whole batch rather than risk a
        # silent accept on parse failure.
        return [
            WordVerdict(word=w, verdict="reject", note="classifier error")
            for w in batch
        ]

    by_word: dict[str, WordVerdict] = {}
    for entry in results:
        if not isinstance(entry, dict):
            continue
        word = str(entry.get("word", "")).strip().lower()
        verdict = str(entry.get("verdict", "")).strip().lower()
        note = str(entry.get("note", "")).strip()[:256]
        if not word or verdict not in ("accept", "reject"):
            continue
        by_word[word] = WordVerdict(word=word, verdict=verdict, note=note)

    # Re-emit in the input order; default missing entries to reject
    # so a malformed model row can never approve by omission.
    return [
        by_word.get(
            w.lower(),
            WordVerdict(word=w.lower(), verdict="reject", note="no verdict returned"),
        )
        for w in batch
    ]
