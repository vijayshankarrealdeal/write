"""Spell-check engine — dictionary lookup + Damerau-Levenshtein suggestions.

The dictionary file lives next to this module (`app/data/en_us.txt`) so
deploys and tests can swap it without changing client code. The set is
loaded once on first call and held in memory for the process lifetime.
"""
from __future__ import annotations

import re
from pathlib import Path
from threading import Lock
from typing import Iterable

_DICT_PATH = Path(__file__).resolve().parent / "data" / "en_us.txt"
_WORD_RE = re.compile(r"[A-Za-z][A-Za-z']*[A-Za-z]|[A-Za-z]")
_TRIM_APOS_RE = re.compile(r"^'+|'+$")
_NUMERIC_RE = re.compile(r"^[0-9]+$")

_dict: set[str] | None = None
_dict_lock = Lock()


def _load_dictionary() -> set[str]:
    global _dict
    if _dict is not None:
        return _dict
    with _dict_lock:
        if _dict is not None:
            return _dict
        words: set[str] = set()
        with _DICT_PATH.open("r", encoding="utf-8") as fh:
            for line in fh:
                w = line.strip()
                if w:
                    words.add(w.lower())
        _dict = words
        return _dict


def _is_known(token: str, dictionary: set[str]) -> bool:
    if len(token) < 2:
        return True
    if _NUMERIC_RE.match(token):
        return True
    return token.lower() in dictionary


class Misspelling(dict):
    """Plain dict so FastAPI serializes it without extra schema noise."""

    def __init__(self, word: str, start: int, length: int) -> None:
        super().__init__(word=word, start=start, length=length)


def check(text: str, ignored: Iterable[str] = ()) -> list[Misspelling]:
    """Scan `text` and return every misspelled word range."""
    if not text:
        return []
    dictionary = _load_dictionary()
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
        if _is_known(trimmed, dictionary):
            continue
        # Possessive: "Bob's" → look up "Bob"
        if lower.endswith("'s"):
            stem = lower[:-2]
            if stem in dictionary:
                continue
        out.append(Misspelling(word=trimmed, start=m.start(), length=len(raw)))
    return out


def suggest(word: str, max_results: int = 5) -> list[str]:
    """Top suggestions for `word`, ranked by Damerau-Levenshtein distance."""
    dictionary = _load_dictionary()
    if not word:
        return []
    lower = word.lower()
    if lower in dictionary:
        return []

    max_dist = 1 if len(lower) <= 4 else 2
    lo = len(lower) - max_dist
    hi = len(lower) + max_dist
    first = lower[0]
    first_code = ord(first)

    candidates: list[tuple[int, int, str]] = []
    for cand in dictionary:
        clen = len(cand)
        if clen < lo or clen > hi:
            continue
        c0 = cand[0]
        if c0 != first and abs(ord(c0) - first_code) > 1:
            continue
        d = _damerau_levenshtein(lower, cand, max_dist)
        if d <= max_dist:
            length_bias = abs(clen - len(lower))
            candidates.append((d, length_bias, cand))

    candidates.sort()
    top = [c[2] for c in candidates[:max_results]]
    return [_match_case(word, t) for t in top]


def _match_case(original: str, suggestion: str) -> str:
    if not original:
        return suggestion
    if original.isupper():
        return suggestion.upper()
    if original[0].isupper() and original[1:].islower():
        return suggestion[0].upper() + suggestion[1:]
    return suggestion


def _damerau_levenshtein(a: str, b: str, max_dist: int) -> int:
    """DL distance with early exit when the running min exceeds max_dist."""
    n, m = len(a), len(b)
    if abs(n - m) > max_dist:
        return max_dist + 1
    prev2 = [0] * (m + 1)
    prev = list(range(m + 1))
    curr = [0] * (m + 1)
    for i in range(1, n + 1):
        curr[0] = i
        row_min = i
        ai = a[i - 1]
        ai_prev = a[i - 2] if i > 1 else ""
        for j in range(1, m + 1):
            cost = 0 if ai == b[j - 1] else 1
            v = min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
            if i > 1 and j > 1 and ai == b[j - 2] and ai_prev == b[j - 1]:
                v = min(v, prev2[j - 2] + cost)
            curr[j] = v
            if v < row_min:
                row_min = v
        if row_min > max_dist:
            return max_dist + 1
        prev2, prev, curr = prev, curr, prev2
    return prev[m]


def warm() -> int:
    """Force-load the dictionary. Returns the entry count."""
    return len(_load_dictionary())
