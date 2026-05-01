"""Quill Delta extraction and reprojection.

The frontend ships its document as a Quill Delta — a list of `{insert, attributes}`
ops. This module:

  1. Splits a delta into paragraphs (text + block + dominant inline attrs).
  2. Joins those plain texts to feed the AI.
  3. Re-projects formatting onto the AI's rewritten text by paragraph index.

Block formatting (header/list/blockquote/align/indent/code-block) survives
intact when paragraph counts roughly line up. Inline formatting is preserved
only when one value dominates ≥50% of the paragraph; stray bold/colored
words inside a sentence are dropped on rewrite — that's by design, not a bug.
"""

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


def extract_paragraphs(delta_ops: list[dict]) -> list[dict]:
    """Walk a Quill Delta and emit paragraph dicts:

        {"text": "...", "block_attrs": {...}, "inline_attrs": {...}}

    Embeds (image/video objects) are skipped — they're not text, and re-stitching
    them around a rewrite is a separate problem. Lossy on roundtrip.
    """
    paragraphs: list[dict] = []
    cur_text = ""
    cur_runs: list[tuple[str, dict]] = []

    for op in delta_ops:
        insert = op.get("insert")
        attrs = op.get("attributes") or {}

        if not isinstance(insert, str):
            # embed (image, video, formula, …) — skip silently
            continue

        # Split on `\n`; each newline closes a paragraph and may carry
        # block-level attributes on its own op.
        parts = insert.split("\n")
        for i, part in enumerate(parts):
            if i > 0:
                block_attrs = {k: v for k, v in attrs.items() if k in _BLOCK_ATTRS}
                paragraphs.append({
                    "text": cur_text,
                    "block_attrs": block_attrs,
                    "inline_attrs": _block_dominant_inline(cur_runs),
                })
                cur_text = ""
                cur_runs = []
            if part:
                inline = {k: v for k, v in attrs.items() if k in _INLINE_ATTRS}
                cur_runs.append((part, inline))
                cur_text += part

    # Trailing chunk with no closing newline (rare — Quill normally appends one).
    if cur_text or cur_runs:
        paragraphs.append({
            "text": cur_text,
            "block_attrs": {},
            "inline_attrs": _block_dominant_inline(cur_runs),
        })

    return paragraphs


def _block_dominant_inline(runs: list[tuple[str, dict]]) -> dict:
    """Inline attrs that cover at least half the paragraph's characters."""
    total = sum(len(t) for t, _ in runs)
    if total == 0:
        return {}

    counts: dict[str, dict[Any, int]] = {}
    for text, attrs in runs:
        for k, v in attrs.items():
            counts.setdefault(k, {})
            key = _to_hashable(v)
            counts[k][key] = counts[k].get(key, 0) + len(text)

    dominant: dict[str, Any] = {}
    for k, vals in counts.items():
        best_val, best_count = max(vals.items(), key=lambda x: x[1])
        if best_count / total >= 0.5:
            dominant[k] = _from_hashable(best_val)
    return dominant


def _to_hashable(v: Any) -> Any:
    if isinstance(v, dict):
        return ("__d__", tuple(sorted(v.items())))
    if isinstance(v, list):
        return ("__l__", tuple(v))
    return v


def _from_hashable(v: Any) -> Any:
    if isinstance(v, tuple) and v and v[0] == "__d__":
        return dict(v[1])
    if isinstance(v, tuple) and v and v[0] == "__l__":
        return list(v[1])
    return v


def reproject_edited(edited_text: str, originals: list[dict]) -> list[dict]:
    """Split AI output into paragraphs, attach formatting from originals by index.

    When the AI returns more paragraphs than the original had, the extras inherit
    the last original's formatting — best we can do without re-prompting.
    """
    edited_paras = _split_paragraphs(edited_text)
    fallback = originals[-1] if originals else {"block_attrs": {}, "inline_attrs": {}}

    result: list[dict] = []
    for i, text in enumerate(edited_paras):
        src = originals[i] if i < len(originals) else fallback
        result.append({
            "text": text,
            "block_attrs": dict(src.get("block_attrs") or {}),
            "inline_attrs": dict(src.get("inline_attrs") or {}),
        })
    return result


def _split_paragraphs(text: str) -> list[str]:
    """Prefer blank-line splits; fall back to single-line splits."""
    blocks = [b.strip() for b in text.split("\n\n") if b.strip()]
    if blocks:
        return blocks
    return [line for line in text.split("\n") if line.strip()]


def paragraphs_to_delta(paragraphs: list[dict]) -> list[dict]:
    """Render a paragraph list back to a Quill Delta. The last op is always
    a `\n` so Quill's document invariant holds."""
    ops: list[dict] = []
    for p in paragraphs:
        text = p.get("text") or ""
        inline = p.get("inline_attrs") or {}
        block = p.get("block_attrs") or {}
        if text:
            op: dict = {"insert": text}
            if inline:
                op["attributes"] = dict(inline)
            ops.append(op)
        nl: dict = {"insert": "\n"}
        if block:
            nl["attributes"] = dict(block)
        ops.append(nl)
    if not ops:
        ops.append({"insert": "\n"})
    return ops
