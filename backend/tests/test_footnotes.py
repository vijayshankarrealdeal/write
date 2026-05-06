"""P1 #5 — section footnotes (inline + inspector panel).

Schema-only tests: pin the model surface, the pydantic schemas, and the
``feed_sections`` endnote-rendering helper without booting Postgres.
End-to-end CRUD is exercised through the Flutter outbox tests on the
client side, plus manual QA. Once ``backend/tests/`` grows a Postgres
fixture, port the upsert behaviour into an integration test.
"""
from __future__ import annotations

from app.feed_sections import _content_with_endnotes, _to_superscript
from app.models.section import Section
from app.schemas.writing import (
    SectionCreate,
    SectionResponse,
    SectionUpdate,
)


def test_section_model_has_footnotes_column():
    """Catch silent column drops/renames before they reach a migration."""
    cols = {c.name for c in Section.__table__.columns}
    assert "footnotes" in cols, f"missing footnotes column. cols={cols}"


def test_section_create_accepts_footnotes():
    """Author-side new-section payloads carry the initial footnote list
    (usually empty, but the field must round-trip through pydantic)."""
    payload = SectionCreate(
        title="Chapter 1",
        footnotes=[
            {"id": "fn-1", "text": "first cite"},
            {"id": "fn-2", "text": "second cite"},
        ],
    )
    dumped = payload.model_dump(exclude_unset=True)
    assert dumped["footnotes"][0]["id"] == "fn-1"
    assert dumped["footnotes"][1]["text"] == "second cite"


def test_section_update_supports_footnote_only_patch():
    """The inspector panel can edit footnotes without touching prose —
    the update schema must accept ``footnotes`` as a sole field so the
    outbox path doesn't have to bundle stale content."""
    payload = SectionUpdate(footnotes=[{"id": "fn-x", "text": "added"}])
    dumped = payload.model_dump(exclude_unset=True)
    assert "footnotes" in dumped
    # Author didn't touch other fields — they should be absent from the
    # exclude_unset dump so the server doesn't overwrite them with None.
    assert "title" not in dumped
    assert "content" not in dumped


def test_section_update_footnotes_default_none():
    """Default = None lets the server distinguish "no change" from
    "explicit empty list" (the latter wipes the section's footnotes)."""
    payload = SectionUpdate(title="rename only")
    assert payload.footnotes is None


def test_section_response_exposes_footnotes_for_realtime():
    """The realtime broadcast and the GET handler both rely on
    SectionResponse — so footnotes must be in the response surface, not
    just the request schemas. Otherwise the editor on a second device
    won't pick up footnote edits."""
    fields = SectionResponse.model_fields
    assert "footnotes" in fields, (
        f"SectionResponse missing footnotes. fields={list(fields)}"
    )


# --- Reader endnote rendering ---


def test_content_with_endnotes_skips_when_no_footnotes():
    delta = [{"insert": "hello world\n"}]
    out = _content_with_endnotes(delta, [])
    assert out == delta


def test_content_with_endnotes_skips_orphans():
    """A footnote whose marker isn't in the delta is treated as a draft
    and excluded from the rendered tail. Otherwise authors who delete a
    marker from the prose but don't garbage-collect the entry leak a
    naked endnote to readers."""
    delta = [{"insert": "no markers here\n"}]
    footnotes = [{"id": "fn-orphan", "text": "ghost"}]
    out = _content_with_endnotes(delta, footnotes)
    assert out == delta


def test_content_with_endnotes_appends_heading_and_numbered_paragraphs():
    """When a delta does cite a footnote, the helper appends a Footnotes
    h3 + one paragraph per cited entry, numbered ¹ ² … in delta order."""
    delta = [
        {"insert": "see "},
        {"insert": {"footnote": "fn-2"}},
        {"insert": " and "},
        {"insert": {"footnote": "fn-1"}},
        {"insert": ".\n"},
    ]
    footnotes = [
        {"id": "fn-1", "text": "first body"},
        {"id": "fn-2", "text": "second body"},
    ]
    out = _content_with_endnotes(delta, footnotes)
    assert out is not None
    # The endnote tail follows the original delta verbatim.
    assert out[: len(delta)] == delta
    tail = out[len(delta):]
    # Heading line: blank \n + 'Footnotes' + h3 \n
    assert tail[0] == {"insert": "\n"}
    assert tail[1] == {"insert": "Footnotes"}
    assert tail[2] == {"insert": "\n", "attributes": {"header": 3}}
    # Numbered bodies — list order, not delta order, drives the visible
    # number. The list ordering is the author's canonical numbering.
    assert tail[3] == {"insert": "¹ first body\n"}
    assert tail[4] == {"insert": "² second body\n"}


def test_content_with_endnotes_drops_duplicate_citations():
    """A footnote referenced twice in the prose still appears once in
    the endnote list — readers don't need ¹ first body / ¹ first body."""
    delta = [
        {"insert": {"footnote": "fn-x"}},
        {"insert": " "},
        {"insert": {"footnote": "fn-x"}},
        {"insert": "\n"},
    ]
    footnotes = [{"id": "fn-x", "text": "cited twice"}]
    out = _content_with_endnotes(delta, footnotes)
    assert out is not None
    tail = out[len(delta):]
    body_inserts = [op["insert"] for op in tail if "footnote" not in str(op)]
    # exactly one numbered body line
    assert "¹ cited twice\n" in body_inserts
    assert sum("¹" in b for b in body_inserts) == 1


def test_content_with_endnotes_passthrough_when_content_not_a_list():
    """Edge case: ``content`` may be ``None`` or a malformed dict on
    very old rows. The helper must not invent a list — return verbatim.
    """
    assert _content_with_endnotes(None, [{"id": "fn-1", "text": "x"}]) is None
    assert _content_with_endnotes(
        {"unexpected": True}, [{"id": "fn-1", "text": "x"}]
    ) == {"unexpected": True}


def test_to_superscript_handles_two_digit_numbers():
    assert _to_superscript(1) == "¹"
    assert _to_superscript(12) == "¹²"
    assert _to_superscript(100) == "¹⁰⁰"


# --- Router surface guard ---


def test_writings_router_section_routes_unchanged():
    """If the section CRUD paths move silently, every Flutter outbox
    op for footnotes (and content) starts 404-ing. Pin the canonical
    paths here."""
    from app.routers import writings as writings_router
    paths = {
        (r.path, tuple(sorted(r.methods - {"HEAD"})))
        for r in writings_router.router.routes
    }
    assert ("/api/writings/{writing_id}/sections", ("GET",)) in paths
    assert ("/api/writings/{writing_id}/sections", ("POST",)) in paths
    assert (
        "/api/writings/{writing_id}/sections/{section_id}",
        ("PUT",),
    ) in paths
    assert (
        "/api/writings/{writing_id}/sections/{section_id}",
        ("DELETE",),
    ) in paths
