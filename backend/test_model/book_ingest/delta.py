"""Build Quill Delta JSON from a chunk's text, highlights, and images.

The Flutter app stores `Section.content` as a Quill Delta — a JSON list of
`{insert: ..., attributes?: {...}}` ops. Image embeds use the
`{insert: {image: "<url>"}}` shape that flutter_quill expects.

Highlight spans are rendered as inline `background` attributes so the
ingested book visually highlights its key passages without needing per-user
Highlight rows.
"""

from __future__ import annotations

from typing import Any

from .image_planner import PlannedScene
from .md_to_delta import markdown_to_ops
from .schemas import ChunkDeep, GeneratedScene, HighlightSpan


# Quill expects every document to end with a trailing "\n".
_TRAILING = {"insert": "\n"}


def build_section_delta(
    chunk_text: str,
    deep: ChunkDeep | None,
    scenes_in_chunk: list[tuple[PlannedScene, GeneratedScene]],
    *,
    image_url_for: callable[[str], str] | None = None,
    cleaned_markdown: str | None = None,
) -> list[dict[str, Any]]:
    """Return a Quill Delta (list of ops) for one section.

    Layout:
      - rich_summary as the opening italic paragraph (if present)
      - first generated image (if any) right after the summary
      - chunk text with paragraph breaks + inline formatting (when
        `cleaned_markdown` is supplied, it's parsed for paragraphing,
        bold/italic, headings, blockquoted verses; otherwise the raw
        chunk text is inserted with highlight backgrounds applied)
      - remaining images appended at the end
    """
    ops: list[dict[str, Any]] = []

    # Skip degraded fallback summaries that the reduce agent writes when
    # its LLM call fails permanently — readers should never see those
    # markers as the section's italic header.
    summary = (deep.rich_summary if deep else None) or ""
    if summary.startswith("[reduce failed:") or summary.startswith("[map failed:"):
        summary = ""
    if summary:
        ops.append({"insert": summary, "attributes": {"italic": True}})
        ops.append({"insert": "\n"})
        ops.append({"insert": "\n"})

    pairs = list(scenes_in_chunk)
    if pairs:
        first_planned, first_scene = pairs[0]
        ops.extend(_image_ops(first_scene, first_planned, image_url_for))
        pairs = pairs[1:]

    if cleaned_markdown and cleaned_markdown.strip():
        # Cleaned-markdown path: parse paragraphs, headings, italics,
        # blockquoted verses. We skip highlight backgrounds in this mode
        # because the highlight spans were computed against the raw
        # chunk text — their character offsets don't align with the
        # rewritten markdown.
        ops.extend(markdown_to_ops(cleaned_markdown))
        if ops and not _ends_with_newline(ops[-1]):
            ops.append(_TRAILING)
    else:
        # Legacy raw-text path with highlight backgrounds.
        spans = sorted(
            (deep.highlight_spans if deep else []),
            key=lambda s: s.start,
        )
        ops.extend(_text_with_highlights(chunk_text, spans))

    for planned, scene in pairs:
        ops.append({"insert": "\n"})
        ops.extend(_image_ops(scene, planned, image_url_for))

    if not ops or ops[-1] != _TRAILING:
        ops.append(_TRAILING)
    return ops


def _ends_with_newline(op: dict[str, Any]) -> bool:
    ins = op.get("insert")
    return isinstance(ins, str) and ins.endswith("\n")


def empty_delta() -> list[dict[str, Any]]:
    return [_TRAILING]


def _text_with_highlights(text: str, spans: list[HighlightSpan]) -> list[dict[str, Any]]:
    """Slice `text` into ops, applying inline `background` to highlighted spans."""
    if not text:
        return []

    valid: list[HighlightSpan] = []
    cursor = 0
    for span in spans:
        if span.start < cursor:
            continue  # overlapping — skip the later one
        if span.start + span.length > len(text):
            continue
        valid.append(span)
        cursor = span.start + span.length

    ops: list[dict[str, Any]] = []
    pos = 0
    for span in valid:
        if span.start > pos:
            ops.append({"insert": text[pos : span.start]})
        ops.append({
            "insert": text[span.start : span.start + span.length],
            "attributes": {"background": span.color_hex},
        })
        pos = span.start + span.length
    if pos < len(text):
        ops.append({"insert": text[pos:]})

    if ops and not ops[-1]["insert"].endswith("\n"):
        ops.append({"insert": "\n"})
    return ops


def _image_ops(
    scene: GeneratedScene,
    planned: PlannedScene,
    url_for: callable[[str], str] | None,
) -> list[dict[str, Any]]:
    src = url_for(scene.image_path) if url_for else scene.image_path
    return [
        {"insert": {"image": src}},
        {"insert": "\n"},
        {"insert": planned.scene_text, "attributes": {"italic": True, "size": "small"}},
        {"insert": "\n"},
    ]
