"""Spell-check engine — backed by `pyspellchecker`.

The previous implementation shipped a homemade word list that only covered
root forms, so common inflections ("typing", "needed", "mattered",
"mapping", "issues" …) were flagged as misspellings. We now use
`pyspellchecker`, whose bundled English dictionary covers inflections and
plurals out of the box, and exposes a frequency-ranked candidate list for
suggestions.

The SpellChecker instance is initialised once and held in memory for the
process lifetime — first-call cost loads the dictionary; subsequent calls
are pure dict lookups.
"""
from __future__ import annotations

import re
from threading import Lock
from typing import Iterable

from spellchecker import SpellChecker

_WORD_RE = re.compile(r"[A-Za-z][A-Za-z']*[A-Za-z]|[A-Za-z]")
_TRIM_APOS_RE = re.compile(r"^'+|'+$")
_NUMERIC_RE = re.compile(r"^[0-9]+$")

_checker: SpellChecker | None = None
_checker_lock = Lock()


def _get_checker() -> SpellChecker:
    global _checker
    if _checker is not None:
        return _checker
    with _checker_lock:
        if _checker is not None:
            return _checker
        _checker = SpellChecker(language="en", distance=2)
        return _checker


def add_words(words: list[str]) -> None:
    """Splice the merged global dictionary into the in-memory checker.

    Called from the admin merge handler after new words are committed
    so subsequent ``/api/spellcheck/check`` requests immediately stop
    flagging them — without waiting for a process restart.
    """
    if not words:
        return
    checker = _get_checker()
    with _checker_lock:
        checker.word_frequency.load_words([w.lower() for w in words])


def remove_words(words: list[str]) -> None:
    """Remove words from the in-memory checker. Called after the admin
    deletes entries from ``dictionary_words``."""
    if not words:
        return
    checker = _get_checker()
    with _checker_lock:
        for w in words:
            checker.word_frequency.remove(w.lower())


def _is_known(token: str, checker: SpellChecker) -> bool:
    if len(token) < 2:
        return True
    if _NUMERIC_RE.match(token):
        return True
    return token.lower() in checker


class Misspelling(dict):
    """Plain dict so FastAPI serializes it without extra schema noise."""

    def __init__(self, word: str, start: int, length: int) -> None:
        super().__init__(word=word, start=start, length=length)


def check(text: str, ignored: Iterable[str] = ()) -> list[Misspelling]:
    """Scan `text` and return every misspelled word range."""
    if not text:
        return []
    checker = _get_checker()
    ignored_lower = {w.lower() for w in ignored}
    out: list[Misspelling] = []
    for m in _WORD_RE.finditer(text):
        raw = m.group(0)
        trimmed = _TRIM_APOS_RE.sub("", raw)
        if len(trimmed) < 2:
            continue
        lower = trimmed.lower()
        if lower in ignored_lower:
            continue
        if _is_known(trimmed, checker):
            continue
        # Possessive: "Bob's" → look up "Bob"
        if lower.endswith("'s") and lower[:-2] in checker:
            continue
        out.append(Misspelling(word=trimmed, start=m.start(), length=len(raw)))
    return out


def suggest(word: str, max_results: int = 5) -> list[str]:
    """Top suggestions for `word`, ranked by edit distance + frequency."""
    if not word:
        return []
    checker = _get_checker()
    lower = word.lower()
    if lower in checker:
        return []
    candidates = checker.candidates(lower) or set()
    if not candidates:
        return []
    # `candidates` is a set; rank by word frequency (higher = more common)
    # and trim to `max_results`. Frequency-based ranking matches what users
    # expect from a "Did you mean…" dropdown.
    ranked = sorted(
        candidates,
        key=lambda w: (-checker.word_usage_frequency(w), w),
    )
    top = ranked[:max_results]
    return [_match_case(word, t) for t in top]


def _match_case(original: str, suggestion: str) -> str:
    if not original:
        return suggestion
    if original.isupper():
        return suggestion.upper()
    if original[0].isupper() and original[1:].islower():
        return suggestion[0].upper() + suggestion[1:]
    return suggestion


def warm() -> int:
    """Force-load the dictionary. Returns the entry count."""
    return len(_get_checker().word_frequency.dictionary)


async def warm_with_global_dict() -> int:
    """Warm the bundled dictionary, then fold in the merged global dict
    persisted in ``dictionary_words``. Returns the total word count.

    Run from the lifespan startup hook so the very first
    ``/api/spellcheck/check`` already knows about every admin-approved
    addition without waiting for the next merge to refresh memory.
    """
    from sqlalchemy import select

    from app.database import async_session
    from app.models.dictionary import DictionaryWord

    warm()
    async with async_session() as session:
        rows = await session.execute(select(DictionaryWord.word))
        words = [r for (r,) in rows.all()]
    if words:
        add_words(words)
    return len(_get_checker().word_frequency.dictionary)
