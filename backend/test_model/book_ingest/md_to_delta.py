"""Convert a markdown subset → Quill Delta ops.

We only handle the markdown features the cleaner agent emits. No tables,
no code fences, no fancy lists. Keeping it small means no external dep.

Mapping:
    paragraph              → text ops + trailing "\n"
    ## heading             → text op + "\n" with attributes={header: 2}
    > blockquote line      → text op + "\n" with attributes={blockquote: true}
    *italic text*          → text op with attributes={italic: true}
    **bold text**          → text op with attributes={bold: true}
    `inline code`          → text op with attributes={code: true}
    blank line             → paragraph break (extra "\n")
"""

from __future__ import annotations

import re
from typing import Any

# Tokenize the inline body of a paragraph/blockquote/heading.
# Order matters: handle bold before italic (bold is **, italic is *).
_INLINE_RE = re.compile(
    r"(\*\*([^*\n]+?)\*\*"        # **bold**
    r"|__([^_\n]+?)__"            # __bold__
    r"|\*((?:[^*\n]|\\\*)+?)\*"   # *italic*
    r"|_((?:[^_\n]|\\_)+?)_"      # _italic_
    r"|`([^`\n]+?)`)"             # `code`
)


def _inline_ops(text: str, base_attrs: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Walk a single line of markdown text and emit Quill ops with
    inline bold/italic/code attributes. base_attrs (e.g. for heading
    color or italic-by-default) merge into every emitted op."""
    base = dict(base_attrs or {})
    out: list[dict[str, Any]] = []
    pos = 0
    for m in _INLINE_RE.finditer(text):
        if m.start() > pos:
            chunk = text[pos:m.start()]
            if chunk:
                out.append(_op(chunk, base))
        # Figure out which kind of inline match it was.
        if m.group(2) is not None or m.group(3) is not None:
            content = m.group(2) or m.group(3) or ""
            out.append(_op(content, {**base, "bold": True}))
        elif m.group(4) is not None or m.group(5) is not None:
            content = m.group(4) or m.group(5) or ""
            # nested **bold *italic*** style — recurse for inner formatting
            for sub in _inline_ops(content, {**base, "italic": True}):
                out.append(sub)
        elif m.group(6) is not None:
            out.append(_op(m.group(6), {**base, "code": True}))
        pos = m.end()
    if pos < len(text):
        out.append(_op(text[pos:], base))
    return out


def _op(text: str, attrs: dict[str, Any]) -> dict[str, Any]:
    if attrs:
        return {"insert": text, "attributes": dict(attrs)}
    return {"insert": text}


def markdown_to_ops(md: str) -> list[dict[str, Any]]:
    """Return Quill Delta ops for the given markdown. The result is NOT
    automatically terminated with a trailing "\n" — callers concat with
    other ops (image embeds, captions) and finalize at the end."""
    lines = md.splitlines()
    ops: list[dict[str, Any]] = []
    para_buf: list[str] = []  # current paragraph being accumulated

    def flush_paragraph():
        nonlocal para_buf
        if not para_buf:
            return
        text = " ".join(para_buf).strip()
        para_buf = []
        if not text:
            return
        ops.extend(_inline_ops(text))
        ops.append({"insert": "\n"})

    for raw in lines:
        line = raw.rstrip()
        # blank line — paragraph break
        if not line.strip():
            flush_paragraph()
            continue
        # heading
        if line.startswith("### "):
            flush_paragraph()
            ops.extend(_inline_ops(line[4:].strip()))
            ops.append({"insert": "\n", "attributes": {"header": 3}})
            continue
        if line.startswith("## "):
            flush_paragraph()
            ops.extend(_inline_ops(line[3:].strip()))
            ops.append({"insert": "\n", "attributes": {"header": 2}})
            continue
        if line.startswith("# "):
            flush_paragraph()
            ops.extend(_inline_ops(line[2:].strip()))
            ops.append({"insert": "\n", "attributes": {"header": 1}})
            continue
        # blockquote (each `> ` line is its own line in the verse)
        if line.lstrip().startswith(">"):
            flush_paragraph()
            content = line.lstrip()[1:].lstrip()
            ops.extend(_inline_ops(content))
            ops.append({"insert": "\n", "attributes": {"blockquote": True}})
            continue
        # horizontal rule
        if line.strip() in {"---", "***", "___"}:
            flush_paragraph()
            ops.append({"insert": "\n"})
            continue
        # otherwise accumulate into the current paragraph
        para_buf.append(line.strip())

    flush_paragraph()
    return ops
