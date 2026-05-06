"""Linguistic Focus engine — POS tagging + dialogue detection.

Powers the editor's "Linguistic Focus" overlay. The user picks one
class (dialogue, adverbs, adjectives, verbs, nouns) and the matching
spans are highlighted; everything else fades. Useful as a self-edit
pass — adverb-spotting, dialogue density, etc.

Two layers:

1. Dialogue is regex-based (no NLP). Handles straight quotes, smart
   quotes, nested quotes (outermost wins), and em-dash conversation
   openers. Works without spaCy installed.

2. POS classes (adverbs / adjectives / verbs / nouns) come from a
   lazily-loaded spaCy `en_core_web_sm` pipeline. The model is heavy,
   so we keep one process-wide instance behind a lock and parse on a
   thread executor at the router layer. When spaCy isn't installed
   (test env, model missing in dev) the POS calls degrade to empty
   lists and the router flags `pos_available=False` so the client can
   show a "POS unavailable" hint instead of silently returning nothing.

All offsets are plain-text Unicode-codepoint indices into the input
text, matching Quill's `Document.toPlainText()` indexing on the
client.
"""
from __future__ import annotations

import re
from threading import Lock
from typing import Iterable


# ─── spaCy model loader ─────────────────────────────────────────────

_nlp = None
_nlp_lock = Lock()
_nlp_load_failed = False


def _get_nlp():
    """Lazily load the English spaCy pipeline.

    Returns None when spaCy isn't importable or the model isn't
    downloaded — caller must treat that as "POS tagging unavailable".
    The first successful load takes ~1s and is cached for the process
    lifetime; subsequent calls are pointer reads.

    `ner` and `lemmatizer` are disabled because we only need
    `tagger`/`attribute_ruler` to populate `token.pos_`.
    """
    global _nlp, _nlp_load_failed
    if _nlp is not None:
        return _nlp
    if _nlp_load_failed:
        return None
    with _nlp_lock:
        if _nlp is not None:
            return _nlp
        if _nlp_load_failed:
            return None
        try:
            import spacy  # type: ignore
            _nlp = spacy.load(
                "en_core_web_sm",
                disable=["ner", "lemmatizer"],
            )
        except Exception:
            _nlp_load_failed = True
            return None
        return _nlp


def pos_available() -> bool:
    """True iff a spaCy model is loaded (or loadable) in this process."""
    return _get_nlp() is not None


# ─── Dialogue detection ─────────────────────────────────────────────

_SMART_DQUOTE_OPEN = "“"   # “
_SMART_DQUOTE_CLOSE = "”"  # ”
_SMART_SQUOTE_OPEN = "‘"   # ‘
_SMART_SQUOTE_CLOSE = "’"  # ’
_EM_DASH = "—"             # —

# Smart-quoted sections: open and close glyphs are distinct so a
# non-greedy match between them is safe even when the text contains
# nested straight quotes. DOTALL lets dialogue cross paragraph breaks
# (rare but legal — multi-line speech in older novels).
_SMART_DQUOTE_RE = re.compile(
    rf"{_SMART_DQUOTE_OPEN}([^{_SMART_DQUOTE_OPEN}{_SMART_DQUOTE_CLOSE}]*?){_SMART_DQUOTE_CLOSE}",
    re.DOTALL,
)
_SMART_SQUOTE_RE = re.compile(
    rf"{_SMART_SQUOTE_OPEN}([^{_SMART_SQUOTE_OPEN}{_SMART_SQUOTE_CLOSE}]*?){_SMART_SQUOTE_CLOSE}",
    re.DOTALL,
)


def _detect_straight_double_quotes(text: str) -> list[tuple[int, int]]:
    """Pair sequential `"` characters: 1st opens, 2nd closes, repeat.

    A trailing unmatched `"` is dropped — the user is likely mid-typing.
    Span includes both quote characters.
    """
    spans: list[tuple[int, int]] = []
    open_idx: int | None = None
    for i, ch in enumerate(text):
        if ch != '"':
            continue
        if open_idx is None:
            open_idx = i
        else:
            spans.append((open_idx, i + 1 - open_idx))
            open_idx = None
    return spans


def _detect_straight_single_quotes(text: str) -> list[tuple[int, int]]:
    """Detect single-quoted dialogue, distinguishing it from apostrophes.

    Heuristic — a straight `'` is a quote boundary only if it sits at a
    *word edge* that points the right way:
      - opens  : preceded by start/space/punct  AND followed by a letter
      - closes : preceded by a letter           AND followed by end/space/punct

    Apostrophes inside contractions ("don't", "it's") and possessives
    ("Bob's") satisfy neither rule, so they're left alone. False
    positives are still possible (e.g. quoted `'twas`); accepted as a
    cost of working without parser context.
    """
    spans: list[tuple[int, int]] = []
    n = len(text)
    open_idx: int | None = None
    for i, ch in enumerate(text):
        if ch != "'":
            continue
        prev_ch = text[i - 1] if i > 0 else ""
        next_ch = text[i + 1] if i + 1 < n else ""
        is_open = (
            (prev_ch == "" or prev_ch.isspace() or (not prev_ch.isalnum() and prev_ch != "'"))
            and next_ch.isalpha()
        )
        is_close = (
            prev_ch.isalpha()
            and (next_ch == "" or next_ch.isspace() or (not next_ch.isalnum() and next_ch != "'"))
        )
        if open_idx is None:
            if is_open:
                open_idx = i
        else:
            if is_close:
                spans.append((open_idx, i + 1 - open_idx))
                open_idx = None
    return spans


def _detect_em_dash_dialogue(text: str) -> list[tuple[int, int]]:
    """Lines opening with an em-dash mark dialogue to end-of-line.

    Spanish, French, and Russian fiction (and some translated/
    literary English) use this convention instead of quote marks:

        — Get away from me, said the captain.

    The span runs from the em-dash to (but not including) the trailing
    newline so the highlight doesn't bleed onto the next line.
    """
    spans: list[tuple[int, int]] = []
    pos = 0
    for line in text.splitlines(keepends=True):
        line_start = pos
        i = line_start
        line_end = line_start + len(line)
        # Skip leading horizontal whitespace.
        while i < line_end and text[i] in " \t":
            i += 1
        if i < line_end and text[i] == _EM_DASH:
            end = line_end
            if line.endswith("\r\n"):
                end -= 2
            elif line.endswith("\n"):
                end -= 1
            if end > i:
                spans.append((i, end - i))
        pos = line_end
    return spans


def detect_dialogue(text: str) -> list[tuple[int, int]]:
    """Return all dialogue spans in [text] as (start, length) tuples.

    Combines smart quotes, straight quotes (heuristic), and em-dash
    openers. Overlapping or adjacent ranges are merged so the client
    paints a flat highlight layer instead of stacking translucent
    rectangles on the same characters.
    """
    if not text:
        return []
    spans: list[tuple[int, int]] = []
    for m in _SMART_DQUOTE_RE.finditer(text):
        spans.append((m.start(), m.end() - m.start()))
    for m in _SMART_SQUOTE_RE.finditer(text):
        spans.append((m.start(), m.end() - m.start()))
    spans.extend(_detect_straight_double_quotes(text))
    spans.extend(_detect_straight_single_quotes(text))
    spans.extend(_detect_em_dash_dialogue(text))
    return _merge_spans(spans)


def _merge_spans(spans: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Sort by start, merge any overlapping/adjacent ranges."""
    if not spans:
        return []
    sorted_spans = sorted(spans, key=lambda s: (s[0], s[1]))
    out: list[tuple[int, int]] = [sorted_spans[0]]
    for start, length in sorted_spans[1:]:
        last_start, last_length = out[-1]
        last_end = last_start + last_length
        if start <= last_end:
            new_end = max(last_end, start + length)
            out[-1] = (last_start, new_end - last_start)
        else:
            out.append((start, length))
    return out


# ─── POS tagging ────────────────────────────────────────────────────

# spaCy POS tag → public class name. AUX (auxiliary verbs: "is",
# "have", "will") groups with VERB and PROPN groups with NOUN so the
# user's mental model — "highlight every verb / every noun" — matches
# the highlight without quibbling over linguistic subcategories.
_POS_MAP = {
    "ADV": "adverbs",
    "ADJ": "adjectives",
    "VERB": "verbs",
    "AUX": "verbs",
    "NOUN": "nouns",
    "PROPN": "nouns",
}


def tag_pos(text: str) -> dict[str, list[tuple[int, int]]]:
    """Run spaCy and return a class → spans dict.

    Returns an empty dict (not partial) when spaCy isn't available, so
    callers can short-circuit rather than iterating four empty lists.
    """
    nlp = _get_nlp()
    if nlp is None or not text:
        return {}
    doc = nlp(text)
    out: dict[str, list[tuple[int, int]]] = {
        "adverbs": [],
        "adjectives": [],
        "verbs": [],
        "nouns": [],
    }
    for token in doc:
        cls = _POS_MAP.get(token.pos_)
        if cls is None:
            continue
        if not token.text.strip():
            continue
        out[cls].append((token.idx, len(token.text)))
    return out


# ─── Public entry point ─────────────────────────────────────────────

ALL_CLASSES = ("dialogue", "adverbs", "adjectives", "verbs", "nouns")


def tag(
    text: str,
    classes: Iterable[str] | None = None,
) -> dict[str, list[dict]]:
    """Top-level entry point. Returns dict of class → list[{start,length}].

    When [classes] is provided, classes outside that set are returned
    as empty lists (we still emit every key so the response shape is
    stable for the client).
    """
    requested = set(classes) if classes else set(ALL_CLASSES)
    out: dict[str, list[dict]] = {c: [] for c in ALL_CLASSES}
    if not text:
        return out
    if "dialogue" in requested:
        out["dialogue"] = [
            {"start": s, "length": ln} for s, ln in detect_dialogue(text)
        ]
    pos_classes = requested & {"adverbs", "adjectives", "verbs", "nouns"}
    if pos_classes:
        pos = tag_pos(text)
        for cls, spans in pos.items():
            if cls in pos_classes:
                out[cls] = [
                    {"start": s, "length": ln} for s, ln in spans
                ]
    return out


def warm() -> bool:
    """Force the spaCy model to load. Returns True iff successful.

    Called from the lifespan startup hook so the first real request
    doesn't pay the model-load latency. Idempotent.
    """
    return _get_nlp() is not None
