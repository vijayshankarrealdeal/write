"""Build Quill Delta JSON from a chunk's text, highlights, and images.

The Flutter app stores `Section.content` as a Quill Delta — a JSON list of
`{insert: ..., attributes?: {...}}` ops. Image embeds use the
`{insert: {image: "<url>"}}` shape that flutter_quill expects.

Highlight spans render as inline `background` attributes so the
ingested book visually highlights its key passages without needing
per-user Highlight rows.

Image placement: each image is anchored to the paragraph in the
chapter text that best matches its `scene_text` (overlapping
keywords). This makes the illustration appear *next to* the moment it
depicts, rather than all images piled at the end. When two scenes
share a chapter we spread them — the second image cannot sit in the
same paragraph as the first.
"""

from __future__ import annotations

import re
from typing import Any

from .image_planner import PlannedScene
from .md_to_delta import markdown_to_ops
from .schemas import ChunkDeep, GeneratedScene, HighlightSpan


# Quill expects every document to end with a trailing "\n".
_TRAILING = {"insert": "\n"}

# A "paragraph break" in a Quill Delta is a string insert that ends in
# "\n". The end-of-paragraph op may also carry block attributes
# (header, blockquote) — we anchor between paragraphs, not inside them.
_WORD_RE = re.compile(r"[A-Za-z][A-Za-z\-']{2,}")


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
      - the section's headline image right after the summary (so the
        chapter has a visual anchor immediately)
      - chunk text with paragraph breaks + inline formatting
      - secondary images woven inline next to the paragraphs whose
        wording matches the scene_text best (keyword overlap), so each
        image lands near the moment it depicts rather than dumped at
        the end of the chapter

    With cleaned_markdown supplied: parse markdown for paragraphing
    + bold/italic/headings/blockquotes, then anchor images between
    paragraphs. Without it: split the raw chunk_text on blank lines
    and apply highlights, then anchor between blocks.
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
    headline: tuple[PlannedScene, GeneratedScene] | None = None
    if pairs:
        headline = pairs[0]
        ops.extend(_image_ops(headline[1], headline[0], image_url_for))
        pairs = pairs[1:]

    # Build the body ops first (without images), then re-thread images
    # into the body at the best paragraph anchors.
    if cleaned_markdown and cleaned_markdown.strip():
        body_ops = markdown_to_ops(cleaned_markdown)
    else:
        spans = sorted(
            (deep.highlight_spans if deep else []),
            key=lambda s: s.start,
        )
        body_ops = _text_with_highlights(chunk_text, spans)

    if pairs:
        body_ops = _weave_images_into_body(body_ops, pairs, image_url_for)

    ops.extend(body_ops)
    if ops and not _ends_with_newline(ops[-1]):
        ops.append(_TRAILING)

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


# -----------------------------------------------------------------------
# Inline image weaving — anchor each scene to the paragraph it depicts
# -----------------------------------------------------------------------

def _weave_images_into_body(
    body_ops: list[dict[str, Any]],
    pairs: list[tuple[PlannedScene, GeneratedScene]],
    url_for: callable[[str], str] | None,
) -> list[dict[str, Any]]:
    """Insert each image at a paragraph boundary near the text it depicts.

    Algorithm:
      1. Split body_ops into "blocks" — runs of ops between paragraph
         breaks (i.e. between ops whose `insert` ends in '\\n').
      2. For each scene, score every block by keyword overlap with the
         scene_text, then pick the highest-scoring block that isn't
         already claimed by an earlier image.
      3. Reassemble: each chosen block is followed by its image ops.

    Fallback: if no block matches (rare — happens when the cleaner
    rewrote the chapter so much that the scene_text shares no
    significant words), the leftover images go at the end of the
    chapter rather than disappearing.
    """
    blocks = _split_into_paragraph_blocks(body_ops)
    if not blocks:
        # No content to weave around — just append images at the end.
        out: list[dict[str, Any]] = list(body_ops)
        for planned, scene in pairs:
            out.append({"insert": "\n"})
            out.extend(_image_ops(scene, planned, url_for))
        return out

    # Score each scene against each block; assign greedily.
    block_texts = [_block_to_text(b).lower() for b in blocks]
    used_blocks: set[int] = set()
    assignments: list[tuple[int, PlannedScene, GeneratedScene]] = []
    leftover: list[tuple[PlannedScene, GeneratedScene]] = []

    for planned, scene in pairs:
        kw = _keywords(planned.scene_text)
        if not kw:
            leftover.append((planned, scene))
            continue
        best_idx = -1
        best_score = 0
        for i, txt in enumerate(block_texts):
            if i in used_blocks:
                continue
            if not txt:
                continue
            score = sum(1 for w in kw if w in txt)
            if score > best_score:
                best_score = score
                best_idx = i
        if best_idx >= 0 and best_score > 0:
            used_blocks.add(best_idx)
            assignments.append((best_idx, planned, scene))
        else:
            leftover.append((planned, scene))

    # Reassemble.
    by_block: dict[int, list[tuple[PlannedScene, GeneratedScene]]] = {}
    for idx, planned, scene in assignments:
        by_block.setdefault(idx, []).append((planned, scene))

    out: list[dict[str, Any]] = []
    for i, block in enumerate(blocks):
        out.extend(block)
        for planned, scene in by_block.get(i, []):
            out.append({"insert": "\n"})
            out.extend(_image_ops(scene, planned, url_for))
    # Any unanchored scenes fall through to the end of the chapter.
    for planned, scene in leftover:
        out.append({"insert": "\n"})
        out.extend(_image_ops(scene, planned, url_for))
    return out


def _split_into_paragraph_blocks(
    body_ops: list[dict[str, Any]],
) -> list[list[dict[str, Any]]]:
    """Group ops into paragraph blocks. Each block is one paragraph's
    worth of ops including its terminating newline op."""
    blocks: list[list[dict[str, Any]]] = []
    current: list[dict[str, Any]] = []
    for op in body_ops:
        current.append(op)
        if _ends_with_newline(op):
            blocks.append(current)
            current = []
    if current:
        blocks.append(current)
    return blocks


def _block_to_text(block: list[dict[str, Any]]) -> str:
    parts: list[str] = []
    for op in block:
        ins = op.get("insert")
        if isinstance(ins, str):
            parts.append(ins)
    return " ".join(parts)


_STOPWORDS = frozenset({
    "the", "and", "for", "with", "from", "into", "that", "this", "they",
    "them", "their", "there", "have", "has", "had", "was", "were", "are",
    "but", "not", "one", "who", "what", "when", "where", "which", "while",
    "her", "his", "him", "she", "you", "your", "our", "out", "over", "all",
    "any", "some", "more", "than", "then", "now", "just", "very", "much",
    "only", "also", "such", "like",
})


def _keywords(text: str) -> set[str]:
    """Lowercased keyword set used to score scene-vs-paragraph overlap.

    Drops short words and a small stopword list. Names, places, and
    distinctive nouns survive — those are what should match the
    scene_text to its paragraph."""
    out: set[str] = set()
    for w in _WORD_RE.findall(text):
        lw = w.lower()
        if lw in _STOPWORDS:
            continue
        out.add(lw)
    return out
