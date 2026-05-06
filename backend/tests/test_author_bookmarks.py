"""P1 #6 — author bookmarks (writer-side flag-this-spot marks).

Schema-only tests in line with `test_bookmarks.py`: pin the model
surface and the router's wire shape without booting Postgres. The
end-to-end CRUD path is exercised through the Flutter outbox tests on
the client side.
"""
from __future__ import annotations

import inspect

import pytest
from pydantic import ValidationError

from app.models.author_bookmark import AuthorBookmark
from app.routers import author_bookmarks as author_bookmarks_router
from app.schemas.author_bookmark import (
    AuthorBookmarkCreate,
    AuthorBookmarkPatch,
    AuthorBookmarkResponse,
)


def test_author_bookmark_model_has_required_columns():
    cols = {c.name for c in AuthorBookmark.__table__.columns}
    expected = {
        "id",
        "user_id",
        "writing_id",
        "section_id",
        "offset",
        "label",
        "color",
        "created_at",
        "updated_at",
    }
    assert expected.issubset(cols), f"missing: {expected - cols}"


def test_author_bookmark_dedupe_constraint_is_declared():
    """The (user, section_id, offset) tuple is the dedupe key the router
    relies on for idempotent upsert. If this constraint moves, the upsert
    path silently breaks — pin it here."""
    constraint_names = {
        c.name for c in AuthorBookmark.__table__.constraints if c.name is not None
    }
    assert "uq_author_bookmark_offset" in constraint_names


def test_author_bookmark_indexes_present():
    """The Inspector's "marks in this section" and project-wide views
    both rely on dedicated indexes. Pin them here so a refactor that
    drops one shows up loud."""
    index_names = {ix.name for ix in AuthorBookmark.__table__.indexes}
    assert "ix_author_bookmarks_user_section" in index_names
    assert "ix_author_bookmarks_user_writing" in index_names


def test_create_validates_non_negative_offset():
    AuthorBookmarkCreate(
        writing_id="00000000-0000-0000-0000-000000000001",
        section_id="sec-1",
        offset=0,
    )
    with pytest.raises(ValidationError):
        AuthorBookmarkCreate(
            writing_id="00000000-0000-0000-0000-000000000001",
            section_id="sec-1",
            offset=-1,
        )


def test_create_defaults_keep_outbox_payload_terse():
    payload = AuthorBookmarkCreate(
        writing_id="00000000-0000-0000-0000-000000000001",
        section_id="sec-1",
        offset=42,
    )
    assert payload.color == "#FFB300"
    assert payload.label is None
    assert payload.client_op_id is None


def test_patch_exposes_offset_unlike_reader_bookmarks():
    """Author bookmarks differ from reader bookmarks in one important
    way: ``offset`` IS patchable, because the client recomputes it via
    Quill delta math whenever text is inserted/deleted before the
    marker. Pin that affordance here so a copy-paste from the reader
    path doesn't accidentally lock it down."""
    fields = AuthorBookmarkPatch.model_fields
    assert "offset" in fields
    assert "label" in fields
    assert "color" in fields


def test_patch_offset_is_non_negative():
    AuthorBookmarkPatch(offset=0)
    with pytest.raises(ValidationError):
        AuthorBookmarkPatch(offset=-1)


def test_router_exposes_expected_routes():
    paths = {
        (r.path, tuple(sorted(r.methods - {"HEAD"})))
        for r in author_bookmarks_router.router.routes
    }
    assert ("/api/author-bookmarks/", ("GET",)) in paths
    assert ("/api/author-bookmarks/", ("POST",)) in paths
    assert (
        "/api/author-bookmarks/{bookmark_id}",
        ("PATCH",),
    ) in paths
    assert (
        "/api/author-bookmarks/{bookmark_id}",
        ("DELETE",),
    ) in paths


def test_router_create_keeps_idempotent_response_signature():
    """The create handler must accept a ``Response`` parameter — that's
    how it returns 200 (existing) vs. 201 (new). If a refactor drops it,
    the Flutter outbox starts seeing 201s for replays and treats them as
    new bookmarks."""
    sig = inspect.signature(author_bookmarks_router.create_author_bookmark)
    assert "response" in sig.parameters


def test_response_schema_is_complete():
    fields = AuthorBookmarkResponse.model_fields
    for name in (
        "id",
        "user_id",
        "writing_id",
        "section_id",
        "offset",
        "label",
        "color",
        "created_at",
        "updated_at",
    ):
        assert name in fields, f"AuthorBookmarkResponse missing {name}"
