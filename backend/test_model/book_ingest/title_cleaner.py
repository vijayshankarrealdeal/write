"""Normalize a book title coming out of a Gutenberg HTML loader.

Gutenberg titles are inconsistent: some are upper-cased ("DRACULA"), most
are mid-sentence-cased ("Frankenstein; or, the modern prometheus"), some
carry a long descriptive subtitle joined with `&#10;` (an HTML-encoded
newline) that's effectively a back-cover blurb, and some carry trailing
punctuation. The Flutter app prints the raw string in a large serif
heading, so cosmetic noise stands out.

Strategy — pure regex, deterministic, no LLM call:

  1. Decode HTML entities (`&#10;` → newline, `&amp;` → `&`).
  2. **Drop only the long descriptive subtitle** that PG appends after a
     newline / em-dash — that's a blurb, not part of the title. Examples:
       'A Modest Proposal\\nFor preventing the children…' → 'A Modest Proposal'
       'My Life — Volume 1' → 'My Life'  (em-dash separates a volume tag)
     **Keep** the canonical `;` / `:` subtitles — those are part of the
     title in the literary catalogue:
       'Frankenstein; or, the modern prometheus'
            → 'Frankenstein; or, the Modern Prometheus'
       'Moby Dick; Or, The Whale' → 'Moby Dick; or, The Whale'
       'Jane Eyre: An Autobiography' → 'Jane Eyre: An Autobiography'
  3. Trim, fix filename-style underscores (`A Doll_s House` → `A Doll's
     House`), strip wrapping quotes and trailing punctuation.
  4. Smart title-case: minor words (the/of/and/...) lowercase except at
     edges or right after `:`. Preserve short acronyms (CIA, NASA) and
     Roman numerals (II, IV). Normalize SHOUTY all-caps titles.

`split_title_subtitle(raw)` returns the raw `(main, subtitle)` tuple
without altering casing — useful when storing both fields separately.
"""

from __future__ import annotations

import html as _html
import re

# Two kinds of "subtitle delimiter":
#
#   _SUBTITLE_SPLIT     — `;`, `:`, em-dash, double-hyphen, or newline.
#                         Used by `split_title_subtitle()` for callers
#                         that want both halves separately.
#
#   _DESCRIPTIVE_DROP   — newline / em-dash / double-hyphen ONLY. These
#                         are PG's "blurb follows" markers (e.g.
#                         '\\nFor preventing the children of poor…',
#                         ' — Volume 1'). Anything after one of these is
#                         dropped by `clean_title()`. `;` and `:` are
#                         preserved so 'Frankenstein; or, the modern
#                         prometheus' stays whole.
_SUBTITLE_SPLIT = re.compile(r"\s*(?:;|:|—|--|\n)\s*", flags=re.UNICODE)
_DESCRIPTIVE_DROP = re.compile(r"\s*(?:—|--|\n)\s*", flags=re.UNICODE)

# Words to keep lower-case unless they are the first or last token.
_LOWERCASE_WORDS: frozenset[str] = frozenset({
    "a", "an", "the",
    "and", "or", "but", "nor", "for", "yet", "so",
    "of", "in", "on", "at", "by", "to", "for", "with", "from",
    "as", "vs", "via",
    "is", "are",  # only when minor (e.g. "Where Are They")
})

# Words that are always all-caps (Roman numerals, well-known acronyms).
_ALWAYS_UPPER: frozenset[str] = frozenset({
    "ii", "iii", "iv", "vi", "vii", "viii", "ix", "xi", "xii", "xiii",
    "xiv", "xv", "xvi", "xvii", "xviii", "xix", "xx",
    "i.", "ii.", "iii.",  # with trailing period
})

# Trailing junk that occasionally rides along on PG titles.
_TRAILING_JUNK = re.compile(r"\s*[.,;:]+\s*$")


def split_title_subtitle(raw: str) -> tuple[str, str | None]:
    """Return (main_title, subtitle_or_None) without altering casing.

    HTML entities are unescaped first (`&#10;` → `\\n`, `&amp;` → `&`)
    so a Gutenberg `<br/>`-encoded subtitle is split correctly even when
    the HTML loader handed us the raw escape sequence.
    """
    if not raw:
        return raw, None
    raw = _html.unescape(raw)
    parts = _SUBTITLE_SPLIT.split(raw, maxsplit=1)
    main = parts[0].strip()
    subtitle = parts[1].strip() if len(parts) > 1 else None
    return main, subtitle


def clean_title(raw: str) -> str:
    """Normalize a book title for display.

    Drops only the descriptive subtitle (newline / em-dash continuation
    that PG uses as a blurb). The canonical `;` / `:` subtitle stays
    attached to the title.

    Examples:
        'Frankenstein; or, the modern prometheus'
            → 'Frankenstein; or, the Modern Prometheus'
        'Moby Dick; Or, The Whale' → 'Moby Dick; or, The Whale'
        'Jane Eyre: An Autobiography' → 'Jane Eyre: An Autobiography'
        'A Modest Proposal\\nFor preventing the children…' → 'A Modest Proposal'
        'My Life — Volume 1' → 'My Life'
        'DRACULA' → 'Dracula'
        'A Doll_s House' → "A Doll's House"
        '  pride and prejudice  ' → 'Pride and Prejudice'
    """
    if not raw:
        return raw

    # Decode HTML entities first (`&#10;` → newline, `&amp;` → `&`).
    text = _html.unescape(raw)

    # Drop the descriptive subtitle (newline / em-dash continuation) but
    # KEEP `;` / `:` subtitles — they're part of the canonical title.
    text = _DESCRIPTIVE_DROP.split(text, maxsplit=1)[0]

    # Filename-style underscores → apostrophes / spaces (Gutenberg's
    # filename munging puts "_" where "'" was: "A Doll_s House").
    text = text.replace("_s ", "'s ")
    text = text.replace("_S ", "'S ")
    if text.endswith("_s"):
        text = text[:-2] + "'s"
    text = text.replace("_", " ")

    # Strip wrapping quotes and trailing punctuation.
    text = text.strip("\"'` \t")
    text = _TRAILING_JUNK.sub("", text)

    # Collapse whitespace, normalise spacing around `;` and `:` so the
    # subtitle reads cleanly: "Frankenstein;or, the…" becomes
    # "Frankenstein; or, the…".
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\s*;\s*", "; ", text)
    text = re.sub(r"\s*:\s*", ": ", text)
    if not text:
        return raw  # never return empty — fall back to the input

    # If the whole title is shouty (all-uppercase letters), lower-case
    # it first so the smart title-case can do its thing. Otherwise
    # `LITTLE WOMEN` would stay all-caps (each token preserved as a
    # short "acronym").
    if _is_shouty(text):
        text = text.lower()

    return _smart_title_case(text)


def _is_shouty(s: str) -> bool:
    """True if every alphabetic char in `s` is upper-case (and there's
    at least one letter). Numbers, punctuation, accents pass through."""
    has_letter = False
    for ch in s:
        if ch.isalpha():
            has_letter = True
            if not ch.isupper():
                return False
    return has_letter


_CONJUNCTIONS: frozenset[str] = frozenset({"or", "and", "but", "nor"})


def _smart_title_case(text: str) -> str:
    """Title-case `text`, keeping minor words (the/of/and/...) lower
    except at edges (first word, last word, or right after `:`/`;`/`.`).

    Special handling for the canonical 'X; or, The Y' subtitle pattern:
    a conjunction (or/and/but) sitting at the post-semicolon edge stays
    lowercase, but the edge passes through to the next word. This makes
    'Moby Dick; or, The Whale' come out the way Wikipedia / Penguin
    print it — `or` lowercase, `The` capitalised.

    Also preserves short all-caps acronyms (CIA, NASA) and Roman numerals
    (II, IV, XIV) intact rather than re-casing them to 'Cia' or 'Iv'."""
    tokens = text.split(" ")
    last_idx = len(tokens) - 1
    out: list[str] = []
    force_capital = True  # first token is always an edge
    for i, tok in enumerate(tokens):
        is_last = (i == last_idx)
        bare = tok.rstrip(".,;:!?").lower()
        is_edge = force_capital or is_last

        # Conjunction sitting at a forced edge → lowercase it, but
        # don't *consume* the edge — let the NEXT word inherit it.
        if force_capital and bare in _CONJUNCTIONS and not is_last and i > 0:
            out.append(_capitalize_token(tok, is_edge=False))
            # force_capital stays True for the next iteration.
            # If this token also ended in `;`/`:`/`.`, that's already
            # accounted for — the flag stays on either way.
            continue

        out.append(_capitalize_token(tok, is_edge=is_edge))

        # Set the flag for the next iteration: ; : . all start a fresh
        # capitalisation context.
        last_char = tok[-1] if tok else ""
        force_capital = last_char in (":", ";", ".")
    return " ".join(out)


def _capitalize_token(tok: str, *, is_edge: bool) -> str:
    if not tok:
        return tok

    # Strip wrapping quotes/parens for analysis, but remember to re-add
    # them. This lets `'Plimoth'` cap correctly to `'Plimoth'`, not
    # `'plimoth'`.
    prefix, core, suffix = _peel_wrappers(tok)
    if not core:
        return tok

    lower = core.lower()
    bare = lower.rstrip(".,;:!?")
    bare_suffix_len = len(core) - len(bare) if bare else 0
    suffix_punct = core[len(core) - bare_suffix_len:] if bare_suffix_len else ""

    # Roman numerals / known acronyms — keep ALL CAPS.
    if bare in _ALWAYS_UPPER or (
        len(bare) >= 1 and bare.isalpha() and _is_roman_numeral(bare)
    ):
        return prefix + bare.upper() + suffix_punct + suffix

    # Short all-caps acronyms (CIA, NASA, USA, FBI, NATO). 2–5 letters,
    # all-alpha, all upper → preserve. Longer ALL-CAPS tokens (LITTLE,
    # WOMEN) are almost always source-casing noise → fall through to
    # normal title-casing.
    bare_letters = core[: len(bare)] if bare else ""
    if (
        2 <= len(bare_letters) <= 5
        and bare_letters.isalpha()
        and bare_letters.isupper()
    ):
        return prefix + core + suffix

    # Mid-title minor words → lowercase, unless this is an edge token.
    # Use `bare` (trailing-punct stripped) so 'or,' still matches 'or'
    # in the lowercase list. Output keeps the trailing punctuation.
    if not is_edge and bare in _LOWERCASE_WORDS:
        return prefix + lower + suffix

    # Hyphenated compound: title-case each side.
    if "-" in core and len(core) > 1:
        parts = core.split("-")
        return prefix + "-".join(_capitalize_token(p, is_edge=True) for p in parts) + suffix

    # Otherwise: capitalize first letter, lower-case the rest. Preserve
    # apostrophes / accents in the middle.
    return prefix + core[:1].upper() + core[1:].lower() + suffix


def _peel_wrappers(tok: str) -> tuple[str, str, str]:
    """Split a token into (leading-punct, core, trailing-punct).
    Used so that `"Plimoth"` capitalises as `"Plimoth"`, not `"plimoth"`.
    """
    lead_re = re.compile(r"^([\(\[\"'`«]+)?")
    trail_re = re.compile(r"([\)\]\"'`»]+)?$")
    lead_m = lead_re.match(tok)
    prefix = lead_m.group(1) if lead_m and lead_m.group(1) else ""
    rest = tok[len(prefix):]
    trail_m = trail_re.search(rest)
    suffix = trail_m.group(1) if trail_m and trail_m.group(1) else ""
    core = rest[: len(rest) - len(suffix)] if suffix else rest
    return prefix, core, suffix


_ROMAN_RE = re.compile(r"^[ivxlcdm]+$")


def _is_roman_numeral(s: str) -> bool:
    return bool(_ROMAN_RE.match(s)) and len(s) >= 1
