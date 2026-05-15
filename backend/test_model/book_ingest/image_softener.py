"""Deterministic prompt-softening rules for the rephrase-retry loop.

Each rule swaps a known trigger word/phrase for a safer near-synonym.
Applied in order. Pure regex — no LLM call. This is attempt 2 of the
5-attempt retry ladder in studio/server.py.
"""
from __future__ import annotations

import re

_RULES: list[tuple[str, str]] = [
    # ── Violence / gore ────────────────────────────────────────────────
    (r"\bblood[-\s]?soaked\b", "battle-worn"),
    (r"\bbloody\b", "stained"),
    (r"\bbleeding\b", "wounded"),
    (r"\bgore\b", "aftermath"),
    (r"\bgory\b", "stark"),
    (r"\bdismembered\b", "broken"),
    (r"\bcorpse(s)?\b", r"fallen figure\1"),
    (r"\bdead body\b", "still figure"),
    (r"\bsevered\b", "broken"),
    (r"\bstabbing\b", "striking"),
    (r"\bslaughter\b", "battle"),
    (r"\bmassacre\b", "great battle"),
    (r"\bbutcher(ed|y)?\b", "felled"),
    (r"\bdecapitat(e|ed|ion)\b", "felled"),

    # ── Sensuality ─────────────────────────────────────────────────────
    (r"\bnude\b", "draped"),
    (r"\bnaked\b", "unclothed in shadow"),
    (r"\bseductive\b", "alluring"),
    (r"\berotic\b", "intimate"),
    (r"\bsensual\b", "tender"),
    (r"\bvoluptuous\b", "graceful"),

    # ── Horror / occult ────────────────────────────────────────────────
    (r"\bdemon(s|ic)?\b", r"shadowed figure\1"),
    (r"\bsatanic\b", "ominous"),
    (r"\btorture(d|s)?\b", r"torment\1"),
    (r"\bhanged\b", "still figure"),
    (r"\bhanging body\b", "still figure"),

    # ── Religious sensitivity ─────────────────────────────────────────
    (r"\bcrucifix(ion|ed)?\b", "figure on a cross"),
    (r"\bmuhammad\b", "the prophet"),
    (r"\bprophet muhammad\b", "the prophet"),

    # ── Children + danger (extra caution) ─────────────────────────────
    (r"\bchild ((?:with|holding|near|in) (?:a |the )?(?:weapon|knife|sword|gun))\b",
     "young figure standing alone"),
]


def soften(prompt: str) -> str:
    """Apply every rule once, in order. Idempotent on already-soft text."""
    out = prompt
    for pattern, replacement in _RULES:
        out = re.sub(pattern, replacement, out, flags=re.IGNORECASE)
    return out
