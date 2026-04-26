"""Phase 3 (P2) — bookmarks + reading-progress anchors.

Schema-only tests: they pin the model surface and the router-level
helpers without booting Postgres. The end-to-end CRUD path is exercised
through the Flutter outbox tests on the client side, plus manual QA;
once `backend/tests/` grows a Postgres fixture, port the create/dedupe
behaviour into an integration test.
"""
from __future__ import annotations

import inspect

import pytest
from pydantic import ValidationError

from app.models.bookmark import Bookmark
from app.models.reading_progress import ReadingProgress
from app.routers import bookmarks as bookmarks_router
from app.schemas.bookmark import (
    BookmarkAnchor,
    BookmarkCreate,
    BookmarkPatch,
    BookmarkResponse,
)
from app.schemas.reading import ContinueReadingItem, ReadingProgressUpdate


def test_bookmark_model_has_required_columns():
    """Catch silent column drops/renames before they reach a migration."""
    cols = {c.name for c in Bookmark.__table__.columns}
    expected = {
        "id",
        "user_id",
        "feed_item_id",
        "section_id",
        "section_index",
        "anchor",
        "label",
        "color",
        "created_at",
        "updated_at",
    }
    assert expected.issubset(cols), f"missing: {expected - cols}"


def test_bookmark_dedupe_constraint_is_declared():
    """The (user, item, section_index, anchor) tuple is the dedupe key
    that the router relies on for idempotent upsert. If this constraint
    moves, the upsert path silently breaks — pin it here."""
    constraint_names = {
        c.name for c in Bookmark.__table__.constraints if c.name is not None
    }
    assert "uq_bookmark_anchor" in constraint_names


def test_reading_progress_has_anchor_columns():
    cols = {c.name for c in ReadingProgress.__table__.columns}
    assert "last_section_id" in cols
    assert "last_anchor" in cols


def test_reading_progress_update_accepts_anchor_payload():
    """The PUT /reading-progress/{id} endpoint must accept the new fields
    so the client can resume from a paragraph instead of a scroll px."""
    payload = ReadingProgressUpdate(
        scroll_position=0.42,
        last_section_id="sec-1",
        last_anchor={"paragraph_idx": 3, "char_offset": 17},
    )
    assert payload.last_section_id == "sec-1"
    assert payload.last_anchor == {"paragraph_idx": 3, "char_offset": 17}


def test_continue_reading_item_serialises():
    """The /continue-reading shape must include enough to render the rail
    without an extra round trip — title, image, anchor, completed flag."""
    fields = ContinueReadingItem.model_fields
    for name in (
        "feed_item_id",
        "title",
        "image_url",
        "scroll_position",
        "last_anchor",
        "last_section_id",
        "completed",
    ):
        assert name in fields, f"ContinueReadingItem missing {name}"


def test_bookmark_anchor_validates_non_negative_offsets():
    BookmarkAnchor(paragraph_idx=0, char_offset=0)
    with pytest.raises(ValidationError):
        BookmarkAnchor(paragraph_idx=-1, char_offset=0)
    with pytest.raises(ValidationError):
        BookmarkAnchor(paragraph_idx=0, char_offset=-5)


def test_bookmark_create_defaults():
    """Defaults make the outbox payload terse — color and section_index
    don't have to be sent if the client is happy with the defaults."""
    payload = BookmarkCreate(
        feed_item_id="00000000-0000-0000-0000-000000000001",
        anchor=BookmarkAnchor(paragraph_idx=2, char_offset=4),
    )
    assert payload.color == "#FFB300"
    assert payload.section_index == 0
    assert payload.label is None


def test_bookmark_patch_does_not_expose_anchor():
    """Anchor is intentionally NOT patchable — moving a bookmark is
    delete + create, not patch (otherwise the dedupe key drifts and the
    edited row collides with someone else's). Pin that here so a future
    'just add anchor' commit fails the test instead of breaking dedupe."""
    fields = BookmarkPatch.model_fields
    assert "anchor" not in fields
    assert "label" in fields
    assert "color" in fields


def test_router_exposes_expected_routes():
    """Belt-and-braces: prefix + canonical paths shouldn't move silently."""
    paths = {(r.path, tuple(sorted(r.methods - {"HEAD"}))) for r in bookmarks_router.router.routes}
    assert ("/api/bookmarks/", ("GET",)) in paths
    assert ("/api/bookmarks/", ("POST",)) in paths
    assert ("/api/bookmarks/{bookmark_id}", ("PATCH",)) in paths
    assert ("/api/bookmarks/{bookmark_id}", ("DELETE",)) in paths
    assert (
        "/api/bookmarks/by-feed-item/{feed_item_id}",
        ("GET",),
    ) in paths


def test_router_create_signature_keeps_idempotent_response():
    """The create handler must accept a `Response` parameter — that's how
    it returns 200 (existing) vs. 201 (new). If a refactor drops it, the
    Flutter outbox starts seeing 201s for replays and treats them as new
    bookmarks."""
    sig = inspect.signature(bookmarks_router.create_bookmark)
    assert "response" in sig.parameters


def test_bookmark_response_schema_is_complete():
    fields = BookmarkResponse.model_fields
    for name in (
        "id",
        "user_id",
        "feed_item_id",
        "section_id",
        "section_index",
        "anchor",
        "label",
        "color",
        "created_at",
        "updated_at",
    ):
        assert name in fields, f"BookmarkResponse missing {name}"
