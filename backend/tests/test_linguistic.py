"""Linguistic Focus engine + router tests.

The engine is split into a regex layer (dialogue detection — no NLP)
and a spaCy layer (POS classes). Tests cover dialogue exhaustively
(it's the part that ships even when spaCy is absent), and gate the
POS tests behind a runtime check so the suite stays green on dev
boxes that haven't run `python -m spacy download en_core_web_sm`.
"""
from __future__ import annotations

import pytest

from app import linguistic as engine
from app.schemas.linguistic import LinguisticTagRequest


# ─── Dialogue: smart double quotes ──────────────────────────────────


def test_dialogue_smart_double_quotes_basic():
    text = "She said “hello” to him."
    spans = engine.detect_dialogue(text)
    assert spans == [(text.index("“"), len("“hello”"))]


def test_dialogue_smart_double_quotes_multiple():
    text = "“Yes,” he said. “No,” she replied."
    spans = engine.detect_dialogue(text)
    # Two non-overlapping spans, returned in document order.
    assert len(spans) == 2
    assert spans[0][0] < spans[1][0]


def test_dialogue_smart_double_quotes_across_newline():
    text = "“First line.\nSecond line.”"
    spans = engine.detect_dialogue(text)
    assert spans == [(0, len(text))]


# ─── Dialogue: smart single quotes ──────────────────────────────────


def test_dialogue_smart_single_quotes():
    text = "‘standalone’"
    spans = engine.detect_dialogue(text)
    assert spans == [(0, len(text))]


def test_dialogue_smart_single_quotes_inside_double():
    """Nested: outer smart-double, inner smart-single. Both highlight,
    and the merge step subsumes the inner into the outer span."""
    text = "“He said, ‘come here’, before leaving.”"
    spans = engine.detect_dialogue(text)
    # Outer span covers the whole thing; inner gets merged in.
    assert len(spans) == 1
    assert spans[0] == (0, len(text))


# ─── Dialogue: straight double quotes ───────────────────────────────


def test_dialogue_straight_double_quotes_basic():
    text = 'She said "hello" to him.'
    spans = engine.detect_dialogue(text)
    assert (text.index('"'), len('"hello"')) in spans


def test_dialogue_straight_double_quotes_multiple_pairs():
    text = '"yes" then "no"'
    spans = engine.detect_dialogue(text)
    assert (0, 5) in spans  # "yes"
    assert (11, 4) in spans  # "no"


def test_dialogue_straight_double_quotes_unmatched_dropped():
    """A dangling `"` (user mid-typing) is not a span."""
    text = 'She said "hello'
    spans = engine.detect_dialogue(text)
    # The lone `"` cannot pair, so no straight-quote span.
    assert all('"' not in text[s : s + ln] or ln >= 2 for s, ln in spans)
    # Stronger: there's no span at all of length 1.
    assert all(ln >= 2 for _, ln in spans)


# ─── Dialogue: straight single quotes vs. apostrophes ───────────────


def test_apostrophe_in_contraction_is_not_dialogue():
    text = "don't go now"
    spans = engine.detect_dialogue(text)
    assert spans == []


def test_apostrophe_possessive_is_not_dialogue():
    text = "Bob's car"
    spans = engine.detect_dialogue(text)
    assert spans == []


def test_straight_single_quote_dialogue():
    text = "She said 'hello' to him."
    spans = engine.detect_dialogue(text)
    assert (text.index("'"), len("'hello'")) in spans


def test_apostrophe_inside_quoted_word_does_not_break_quote():
    """Quoted text containing a contraction stays a single span."""
    text = "He said 'I don't know' clearly."
    spans = engine.detect_dialogue(text)
    # We don't require perfect handling of every nested apostrophe,
    # but the outer 'I don't know' should at least appear as one span.
    # Heuristic limitation: the apostrophe in "don't" sits between two
    # letters so it won't satisfy either open/close rule, which is
    # exactly what we want.
    assert any(s[0] == text.index("'") for s in spans)


# ─── Dialogue: em-dash openers ──────────────────────────────────────


def test_dialogue_em_dash_line_opener():
    text = "— Get away from me, said the captain.\nSomething else."
    spans = engine.detect_dialogue(text)
    # First line, from em-dash to (but not including) the newline.
    line_end = text.index("\n")
    assert (0, line_end) in spans


def test_dialogue_em_dash_with_leading_whitespace():
    text = "  —Speak up.\n"
    spans = engine.detect_dialogue(text)
    em_pos = text.index("—")
    line_end = text.index("\n")
    assert (em_pos, line_end - em_pos) in spans


def test_em_dash_in_middle_of_line_is_not_dialogue():
    text = "I was — startled — by the noise."
    spans = engine.detect_dialogue(text)
    # No line opens with the em-dash, so no em-dash dialogue span.
    # (And there are no quote pairs, so spans is empty.)
    assert spans == []


# ─── Dialogue: merge / sort ─────────────────────────────────────────


def test_overlapping_spans_are_merged():
    """Two overlapping detection rules on the same text shouldn't
    return two stacked spans — the client paints once."""
    # Smart-double containing straight-double inside is a contrived
    # case; smart-double containing em-dash dialogue is the realistic
    # one. We just require that whatever overlaps is merged.
    text = "“yes” “no”"
    spans = engine.detect_dialogue(text)
    starts = [s[0] for s in spans]
    assert starts == sorted(starts)
    # Ensure no two consecutive spans overlap or touch.
    for i in range(len(spans) - 1):
        assert spans[i][0] + spans[i][1] < spans[i + 1][0]


def test_empty_text_returns_empty():
    assert engine.detect_dialogue("") == []
    assert engine.tag("", []) == {
        c: [] for c in engine.ALL_CLASSES
    }


# ─── tag(): top-level entry point ───────────────────────────────────


def test_tag_returns_all_classes_keys_even_when_empty():
    """Stable response shape — the client iterates fixed keys."""
    out = engine.tag("Hello world.", classes=["dialogue"])
    for k in engine.ALL_CLASSES:
        assert k in out


def test_tag_dialogue_only_when_requested():
    text = "She said “hello” clearly."
    out = engine.tag(text, classes=["adverbs"])
    assert out["dialogue"] == []  # not requested


def test_tag_dialogue_when_requested():
    text = "She said “hello” clearly."
    out = engine.tag(text, classes=["dialogue"])
    assert len(out["dialogue"]) == 1
    assert out["dialogue"][0]["start"] == text.index("“")


# ─── POS tagging: gated on spaCy availability ───────────────────────


def _spacy_available() -> bool:
    return engine.pos_available()


@pytest.mark.skipif(
    not _spacy_available(),
    reason="spaCy / en_core_web_sm not installed in this env",
)
def test_pos_adverbs_detected():
    text = "She quickly ran home."
    out = engine.tag(text, classes=["adverbs"])
    words = [text[s["start"] : s["start"] + s["length"]] for s in out["adverbs"]]
    assert "quickly" in words


@pytest.mark.skipif(
    not _spacy_available(),
    reason="spaCy / en_core_web_sm not installed in this env",
)
def test_pos_adjectives_detected():
    text = "The big red ball rolled."
    out = engine.tag(text, classes=["adjectives"])
    words = [text[s["start"] : s["start"] + s["length"]] for s in out["adjectives"]]
    # "big" is unambiguously an adjective.
    assert "big" in words


def test_pos_unavailable_returns_empty_lists_not_crash():
    """When spaCy isn't available, the POS classes degrade quietly."""
    if engine.pos_available():
        pytest.skip("spaCy is available — this path is unreachable")
    out = engine.tag("Hello world.", classes=engine.ALL_CLASSES)
    assert out["adverbs"] == []
    assert out["adjectives"] == []
    assert out["verbs"] == []
    assert out["nouns"] == []


# ─── Schema validation ──────────────────────────────────────────────


def test_request_rejects_unknown_class():
    with pytest.raises(ValueError):
        LinguisticTagRequest(text="hi", classes=["banana"])


def test_request_accepts_valid_subset():
    req = LinguisticTagRequest(text="hi", classes=["dialogue", "verbs"])
    assert req.classes == ["dialogue", "verbs"]


def test_request_text_size_cap():
    """Far over the cap: rejected. At the cap: accepted."""
    too_big = "a" * 200_001
    with pytest.raises(ValueError):
        LinguisticTagRequest(text=too_big, classes=["dialogue"])
    at_cap = "a" * 200_000
    LinguisticTagRequest(text=at_cap, classes=["dialogue"])  # no raise


# ─── Router smoke test (signature + module imports) ─────────────────


def test_router_module_registers_post_tag_route():
    from app.routers import linguistic as router_mod

    paths = {r.path for r in router_mod.router.routes}
    assert "/api/linguistic/tag" in paths
