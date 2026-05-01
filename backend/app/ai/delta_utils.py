"""Quill Delta extraction and reprojection.

The frontend ships its document as a Quill Delta — a list of `{insert, attributes}`
ops. This module:

  1. Splits a delta into paragraphs, preserving every formatted run inside.
  2. Joins the plain texts to feed the AI (no JSON, no markup).
  3. Re-projects formatting onto the AI's rewritten text via word-level LCS:
     each rewrite word that matches an original word inherits that original
     word's attributes exactly; inserted/changed words inherit from the
     nearest matched neighbour. Block formatting still maps paragraph-by-
     paragraph.

Why this works: a word that survives the rewrite keeps its exact formatting
(font, size, bold, color — everything). Only words the AI actually changed
fall back to neighbour inheritance, and even then they pick up the formatting
of the surrounding context, which is usually right.
"""

from __future__ import annotations

import re
from typing import Any

# Attributes that live on the trailing `\n` insert and apply to the whole line.
_BLOCK_ATTRS = {
    "header", "list", "blockquote", "code-block",
    "align", "indent", "direction",
}

# Attributes that live on text inserts and apply to the spans they decorate.
_INLINE_ATTRS = {
    "bold", "italic", "underline", "strike",
    "color", "background", "font", "size",
    "link", "code",
}

# Word + whitespace tokenizer. Each match is either a non-space run or a
# whitespace run; concatenating them reproduces the input exactly.
_WORD_RE = re.compile(r"\S+|\s+")


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

def extract_paragraphs(delta_ops: list[dict]) -> list[dict]:
    """Walk a Quill Delta and emit paragraph dicts:

        {
          "text": "...",
          "block_attrs": {...},
          "runs": [{"text": "...", "attrs": {...}}, ...],
        }

    Every formatted span is preserved as a run, so reprojection can be done
    word-by-word later. Embeds (image/video objects) are skipped — they're
    not text, and re-stitching them around a rewrite is a separate problem.
    """
    paragraphs: list[dict] = []
    cur: list[tuple[str, dict]] = []  # (text, inline_attrs)

    for op in delta_ops:
        insert = op.get("insert")
        attrs = op.get("attributes") or {}

        if not isinstance(insert, str):
            continue  # embeds — skip

        parts = insert.split("\n")
        for i, part in enumerate(parts):
            if i > 0:
                # Each `\n` ends a paragraph; that op may also carry block
                # attributes (header/list/etc.) for the line we just closed.
                block_attrs = {k: v for k, v in attrs.items() if k in _BLOCK_ATTRS}
                paragraphs.append({
                    "text": "".join(t for t, _ in cur),
                    "block_attrs": block_attrs,
                    "runs": _coalesce_runs(cur),
                })
                cur = []
            if part:
                inline = {k: v for k, v in attrs.items() if k in _INLINE_ATTRS}
                cur.append((part, inline))

    # Trailing chunk with no closing newline (rare).
    if cur:
        paragraphs.append({
            "text": "".join(t for t, _ in cur),
            "block_attrs": {},
            "runs": _coalesce_runs(cur),
        })

    return paragraphs


def _coalesce_runs(pairs: list[tuple[str, dict]]) -> list[dict]:
    """Merge adjacent runs that share the exact same attribute set."""
    out: list[dict] = []
    for text, attrs in pairs:
        if out and out[-1]["attrs"] == attrs:
            out[-1]["text"] += text
        else:
            out.append({"text": text, "attrs": dict(attrs)})
    return out


# ---------------------------------------------------------------------------
# Reprojection
# ---------------------------------------------------------------------------

def reproject_edited(edited_text: str, originals: list[dict]) -> list[dict]:
    """Split AI output into paragraphs, then word-align each against the
    matching original paragraph to copy formatting back."""
    edited_paras = _split_paragraphs(edited_text)
    fallback = originals[-1] if originals else {"block_attrs": {}, "runs": []}

    result: list[dict] = []
    for i, text in enumerate(edited_paras):
        src = originals[i] if i < len(originals) else fallback
        orig_tokens = _tokenize_with_attrs(src.get("runs") or [])
        aligned = _align_words(orig_tokens, text)
        runs = _runs_from_words(aligned)
        result.append({
            "text": text,
            "block_attrs": dict(src.get("block_attrs") or {}),
            "runs": runs,
        })
    return result


def _split_paragraphs(text: str) -> list[str]:
    """Prefer blank-line splits; fall back to single-line splits."""
    blocks = [b.strip() for b in text.split("\n\n") if b.strip()]
    if blocks:
        return blocks
    return [line for line in text.split("\n") if line.strip()]


def _tokenize_with_attrs(runs: list[dict]) -> list[tuple[str, dict]]:
    """Walk runs char-by-char to build a per-character attribute table, then
    re-tokenize into (word, attrs) pairs. Each word gets the attrs of its
    first character — close enough; formatting boundaries usually fall on
    word boundaries anyway."""
    char_attrs: list[dict] = []
    chars: list[str] = []
    for r in runs:
        text = r.get("text") or ""
        attrs = r.get("attrs") or {}
        for ch in text:
            chars.append(ch)
            char_attrs.append(attrs)

    full = "".join(chars)
    out: list[tuple[str, dict]] = []
    pos = 0
    for m in _WORD_RE.finditer(full):
        word = m.group(0)
        attrs = char_attrs[pos] if pos < len(char_attrs) else {}
        out.append((word, attrs))
        pos += len(word)
    return out


def _align_words(
    originals: list[tuple[str, dict]],
    edited_text: str,
) -> list[tuple[str, dict]]:
    """LCS-align the rewritten paragraph against the original word sequence.

    For each rewrite word:
      - exact match in original → carry that word's attrs verbatim
      - inserted / changed → inherit from the nearest matched neighbour
        (left first, then right)
      - no matches at all → fall back to the first original word's attrs
    """
    edited_tokens = _WORD_RE.findall(edited_text)
    m = len(originals)
    n = len(edited_tokens)

    if n == 0:
        return []
    if m == 0:
        return [(t, {}) for t in edited_tokens]

    # LCS table on word equality.
    dp = [[0] * (n + 1) for _ in range(m + 1)]
    for i in range(1, m + 1):
        oi = originals[i - 1][0]
        for j in range(1, n + 1):
            if oi == edited_tokens[j - 1]:
                dp[i][j] = dp[i - 1][j - 1] + 1
            else:
                dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])

    # Backtrack: matched[j] holds the original attrs for edited[j], or None.
    matched: list[dict | None] = [None] * n
    i, j = m, n
    while i > 0 and j > 0:
        if originals[i - 1][0] == edited_tokens[j - 1]:
            matched[j - 1] = originals[i - 1][1]
            i -= 1
            j -= 1
        elif dp[i - 1][j] >= dp[i][j - 1]:
            i -= 1
        else:
            j -= 1

    # Forward-fill: each unmatched word inherits attrs from the previous matched word.
    resolved: list[dict | None] = list(matched)
    last: dict | None = None
    for k in range(n):
        if resolved[k] is not None:
            last = resolved[k]
        elif last is not None:
            resolved[k] = last

    # Backward-fill: words before the first match still need attrs.
    last = None
    for k in range(n - 1, -1, -1):
        if matched[k] is not None:
            last = matched[k]
        elif resolved[k] is None and last is not None:
            resolved[k] = last

    # Final fallback: zero matches → use the first original's attrs (better
    # than empty, since the rewrite is presumably meant to live in the same
    # styled context).
    fallback = originals[0][1]
    return [
        (edited_tokens[k], dict(resolved[k] if resolved[k] is not None else fallback))
        for k in range(n)
    ]


def _runs_from_words(words: list[tuple[str, dict]]) -> list[dict]:
    """Coalesce consecutive same-attrs words into runs."""
    out: list[dict] = []
    for text, attrs in words:
        if out and out[-1]["attrs"] == attrs:
            out[-1]["text"] += text
        else:
            out.append({"text": text, "attrs": dict(attrs)})
    return out


# ---------------------------------------------------------------------------
# Delta rendering
# ---------------------------------------------------------------------------

def paragraphs_to_delta(paragraphs: list[dict]) -> list[dict]:
    """Render paragraphs (with their runs) back to a Quill Delta. Always
    ends with a `\n` so Quill's document invariant holds."""
    ops: list[dict] = []
    for p in paragraphs:
        runs = p.get("runs") or []
        if runs:
            for r in runs:
                text = r.get("text") or ""
                if not text:
                    continue
                op: dict = {"insert": text}
                attrs = r.get("attrs") or {}
                if attrs:
                    op["attributes"] = dict(attrs)
                ops.append(op)
        else:
            text = p.get("text") or ""
            if text:
                ops.append({"insert": text})

        nl: dict = {"insert": "\n"}
        block = p.get("block_attrs") or {}
        if block:
            nl["attributes"] = dict(block)
        ops.append(nl)

    if not ops:
        ops.append({"insert": "\n"})
    return ops
