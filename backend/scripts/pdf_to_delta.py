"""Convert a PDF into Quill Delta JSON, preserving headings, bold, and italic.

Heuristics tuned for the Siva Puranam PDF, but generic enough to work on any
similarly-typeset book:
  * size >= 18  -> header level 1 (title)
  * size >= 13.5 -> header level 2 (chapter heading)
  * size >= 12.5 -> header level 3 (sub-heading)
  * flag bit 4 (16) or bold-named font -> bold
  * flag bit 1 (2) or italic-named font -> italic

Skips the recurring "Siva Puranam" running head and the page number digits
that PyMuPDF tags with the ArialMT font.

Usage:
    python scripts/pdf_to_delta.py <input.pdf> <output.json> [--start-at REGEX]

`--start-at REGEX` drops everything before the first line matching REGEX
(used to skip front matter). Lines matching `^PART\\b` are auto-promoted
to header level 1.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import fitz


PART_RE = re.compile(r"^\s*PART\b", re.IGNORECASE)


RUNNING_HEAD_RE = re.compile(r"^\s*siva\s+puranam\s*$", re.IGNORECASE)
PAGE_NUM_RE = re.compile(r"^\s*\d{1,4}\s*$")


def span_is_bold(span: dict) -> bool:
    if span["flags"] & 16:
        return True
    font = span.get("font", "")
    return "Bold" in font


def span_is_italic(span: dict) -> bool:
    if span["flags"] & 2:
        return True
    font = span.get("font", "")
    return "Italic" in font or "Oblique" in font


def line_text(line: dict) -> str:
    return "".join(s["text"] for s in line["spans"])


def line_max_size(line: dict) -> float:
    sizes = [s["size"] for s in line["spans"] if s["text"].strip()]
    return max(sizes) if sizes else 0.0


def heading_level(size: float) -> int | None:
    if size >= 18.0:
        return 1
    if size >= 13.5:
        return 2
    if size >= 12.5:
        return 3
    return None


def is_skip_line(line: dict) -> bool:
    text = line_text(line).strip()
    if not text:
        return False
    if RUNNING_HEAD_RE.match(text):
        # Only the small italic running head — leave the title/big headings.
        if line_max_size(line) < 13.5:
            return True
    if PAGE_NUM_RE.match(text):
        # Only treat as page number if it's standalone in Arial (the body
        # uses Times) — this avoids stripping legitimate "1." enumerations.
        if all(s.get("font", "").startswith("Arial") for s in line["spans"] if s["text"].strip()):
            return True
    return False


class DeltaBuilder:
    """Accumulates Quill Delta ops, merging adjacent text with identical attrs."""

    def __init__(self) -> None:
        self.ops: list[dict] = []

    def push(self, text: str, attrs: dict | None = None) -> None:
        if not text:
            return
        op: dict = {"insert": text}
        if attrs:
            op["attributes"] = dict(attrs)
        if self.ops and "insert" in self.ops[-1] and isinstance(self.ops[-1]["insert"], str):
            prev = self.ops[-1]
            prev_attrs = prev.get("attributes")
            if prev_attrs == op.get("attributes") and not text.startswith("\n") and not prev["insert"].endswith("\n"):
                prev["insert"] += text
                return
        self.ops.append(op)

    def push_newline(self, line_attrs: dict | None = None) -> None:
        op: dict = {"insert": "\n"}
        if line_attrs:
            op["attributes"] = dict(line_attrs)
        self.ops.append(op)


def normalize(text: str) -> str:
    text = text.replace("­", "")  # soft hyphens
    text = text.replace(" ", " ")  # nbsp
    return text


def convert(pdf_path: Path, start_at: re.Pattern | None = None) -> dict:
    doc = fitz.open(str(pdf_path))
    builder = DeltaBuilder()
    started = start_at is None  # if no marker, start immediately

    for page in doc:
        d = page.get_text("dict")
        for block in d.get("blocks", []):
            if block.get("type") != 0:
                continue
            for line in block.get("lines", []):
                spans = [s for s in line.get("spans", []) if s.get("text")]
                if not spans:
                    continue
                if is_skip_line(line):
                    continue

                size = line_max_size(line)
                level = heading_level(size)
                text_stripped = line_text(line).strip()

                if not started:
                    if start_at and start_at.search(text_stripped):
                        started = True
                    else:
                        continue

                # Body text spans.
                body_spans = [s for s in spans if s["text"].strip() or " " in s["text"]]
                if not any(s["text"].strip() for s in body_spans):
                    continue

                # Promote major section dividers ("PART - I", "PART II") to H1.
                if PART_RE.match(text_stripped):
                    level = 1

                if level is not None:
                    text = normalize(line_text(line)).strip()
                    if not text:
                        continue
                    builder.push(text)
                    builder.push_newline({"header": level})
                else:
                    for span in spans:
                        text = normalize(span["text"])
                        if not text:
                            continue
                        attrs = {}
                        if span_is_bold(span):
                            attrs["bold"] = True
                        if span_is_italic(span):
                            attrs["italic"] = True
                        builder.push(text, attrs or None)
                    builder.push_newline()

    doc.close()
    return {"ops": builder.ops}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="input PDF path")
    parser.add_argument("output", help="output JSON path")
    parser.add_argument(
        "--start-at",
        default=None,
        help="regex; skip everything until a line matches (e.g. '^PART\\b')",
    )
    args = parser.parse_args(argv[1:])

    src = Path(args.input)
    dst = Path(args.output)
    if not src.exists():
        print(f"not found: {src}", file=sys.stderr)
        return 2
    pattern = re.compile(args.start_at, re.IGNORECASE) if args.start_at else None
    delta = convert(src, start_at=pattern)
    dst.write_text(json.dumps(delta, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {dst}  ({len(delta['ops'])} ops, {dst.stat().st_size/1024:.1f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
