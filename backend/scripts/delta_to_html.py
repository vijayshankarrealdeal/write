"""Render a Quill Delta JSON file as a standalone HTML preview.

Usage:
    python scripts/delta_to_html.py <input.delta.json> <output.html>

Supported attributes: header (1-6), bold, italic, underline, strike, code, link.
Anything else is ignored.
"""

from __future__ import annotations

import html
import json
import sys
from pathlib import Path


INLINE_OPEN = {
    "bold": "<strong>",
    "italic": "<em>",
    "underline": "<u>",
    "strike": "<s>",
    "code": "<code>",
}
INLINE_CLOSE = {
    "bold": "</strong>",
    "italic": "</em>",
    "underline": "</u>",
    "strike": "</s>",
    "code": "</code>",
}


def render_inline(text: str, attrs: dict) -> str:
    out = html.escape(text)
    if attrs.get("link"):
        href = html.escape(str(attrs["link"]), quote=True)
        out = f'<a href="{href}">{out}</a>'
    for key in ("code", "strike", "underline", "italic", "bold"):
        if attrs.get(key):
            out = INLINE_OPEN[key] + out + INLINE_CLOSE[key]
    return out


def delta_to_html(ops: list[dict]) -> str:
    """Walk ops, accumulating inline HTML for the current line; flush on each
    newline-insert using the newline's line-level attributes."""
    body: list[str] = []
    line_buf: list[str] = []

    def flush(line_attrs: dict) -> None:
        content = "".join(line_buf)
        line_buf.clear()
        header = line_attrs.get("header")
        if isinstance(header, int) and 1 <= header <= 6:
            body.append(f"<h{header}>{content or '&nbsp;'}</h{header}>")
        elif line_attrs.get("blockquote"):
            body.append(f"<blockquote>{content or '&nbsp;'}</blockquote>")
        else:
            body.append(f"<p>{content or '&nbsp;'}</p>")

    for op in ops:
        text = op.get("insert")
        if not isinstance(text, str):
            continue
        attrs = op.get("attributes") or {}

        # Split on newlines so each "\n" can carry its own line-level attrs.
        parts = text.split("\n")
        for i, part in enumerate(parts):
            if part:
                line_buf.append(render_inline(part, attrs))
            if i < len(parts) - 1:
                # The newline itself gets the op's attrs as line-level.
                flush(attrs)

    if line_buf:
        flush({})

    return "\n".join(body)


HTML_SHELL = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<style>
  :root {{ color-scheme: light; }}
  body {{
    max-width: 720px;
    margin: 2.5rem auto;
    padding: 0 1.5rem 4rem;
    font: 16px/1.6 "Georgia", "Times New Roman", serif;
    color: #1d1d1f;
    background: #fafaf7;
  }}
  h1, h2, h3, h4, h5, h6 {{
    font-family: "Helvetica Neue", system-ui, sans-serif;
    color: #3a1c0f;
    line-height: 1.25;
    margin: 2.2rem 0 0.6rem;
  }}
  h1 {{ font-size: 2.1rem; text-align: center; margin-top: 1rem; }}
  h2 {{ font-size: 1.4rem; border-bottom: 1px solid #d8c8b0; padding-bottom: 0.25rem; }}
  h3 {{ font-size: 1.1rem; color: #7a2e1f; }}
  p {{ margin: 0 0 0.85rem; text-align: justify; text-indent: 1.2em; }}
  p:first-of-type, h1 + p, h2 + p, h3 + p {{ text-indent: 0; }}
  strong {{ color: #2a1208; }}
  em {{ color: #5b2a14; }}
  blockquote {{
    border-left: 3px solid #c9a86a;
    margin: 1rem 0;
    padding: 0.25rem 1rem;
    color: #5b4a30;
    font-style: italic;
  }}
  a {{ color: #7a2e1f; }}
</style>
</head>
<body>
{body}
</body>
</html>
"""


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: delta_to_html.py <input.delta.json> <output.html>", file=sys.stderr)
        return 2
    src = Path(argv[1])
    dst = Path(argv[2])
    delta = json.loads(src.read_text(encoding="utf-8"))
    body = delta_to_html(delta.get("ops", []))
    dst.write_text(
        HTML_SHELL.format(title=src.stem, body=body),
        encoding="utf-8",
    )
    print(f"wrote {dst}  ({dst.stat().st_size/1024:.1f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
