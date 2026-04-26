"""Phase 1 — semantic recommendations.

These tests stay deterministic and free of any DB dependency: they
exercise the score path with a hand-built `UserProfile` and the
embedding-text composition with a hand-built `FeedItem`. The KNN
ordering is verified end-to-end in the integration suite once a
pgvector-enabled Postgres is available.
"""
from __future__ import annotations

import uuid
from datetime import UTC, datetime
from types import SimpleNamespace

import pytest

from app.ai.embeddings import build_embedding_text
from app.ai.recommendation import UserProfile, score_item


def _fake_item(
    *,
    iid: str | None = None,
    title: str = "T",
    genres: list[str] | None = None,
    tags: list[str] | None = None,
    likes: int = 0,
    description: str | None = None,
    sections: list[dict] | None = None,
):
    """Build a minimal stand-in that quacks like a SQLAlchemy FeedItem
    well enough for `score_item` and `build_embedding_text` to consume.
    """
    return SimpleNamespace(
        id=iid or str(uuid.uuid4()),
        title=title,
        description=description,
        genres=genres or [],
        tags=tags or [],
        writing_types=[],
        likes_count=likes,
        comments_count=0,
        created_at=datetime.now(UTC),
        sections=sections,
    )


def test_semantic_boost_lifts_score_above_a_neutral_item():
    """An item present in semantic_boost should outrank an otherwise
    identical item that isn't — that's the whole point of the boost."""
    profile = UserProfile()
    a = _fake_item()
    b = _fake_item()
    profile.semantic_boost = {str(a.id): 0.9}

    score_a = score_item(a, profile)
    score_b = score_item(b, profile)
    assert score_a > score_b


def test_semantic_boost_zero_means_no_change():
    """A zero entry shouldn't change the score vs. an item not in the
    boost dict at all — guards against accidental sign flips."""
    profile = UserProfile()
    a = _fake_item()
    b = _fake_item()
    profile.semantic_boost = {str(a.id): 0.0}

    assert score_item(a, profile) == pytest.approx(score_item(b, profile))


def test_semantic_boost_scales_linearly():
    """Doubling the cosine similarity should roughly double the
    contribution. Non-semantic terms are identical between the two."""
    profile_low = UserProfile()
    profile_high = UserProfile()
    item = _fake_item()
    profile_low.semantic_boost = {str(item.id): 0.2}
    profile_high.semantic_boost = {str(item.id): 0.8}

    low = score_item(item, profile_low)
    high = score_item(item, profile_high)
    assert high - low == pytest.approx(0.6 * 3.0, rel=0.01)


def test_build_embedding_text_combines_title_description_body():
    """Embedding input should glue together the high-signal fields."""
    item = _fake_item(
        title="The Quiet Year",
        description="A village survives the winter.",
        sections=[{"text": "Snow fell on the ridge for forty days."}],
    )
    text = build_embedding_text(item)
    assert "The Quiet Year" in text
    assert "village survives" in text
    assert "Snow fell on the ridge" in text


def test_build_embedding_text_handles_quill_ops():
    """`sections` can be a Quill-style ops list; we should pull insert text."""
    item = _fake_item(
        title="Drift",
        sections=[
            {"ops": [{"insert": "Chapter 1\n"}, {"insert": "It begins."}]},
        ],
    )
    text = build_embedding_text(item)
    assert "Chapter 1" in text and "It begins." in text


def test_build_embedding_text_truncates_long_bodies():
    """Body coalescing must respect the 2k char cap so we don't blow
    past the embedding-model context window for long writings."""
    long_body = "x" * 5000
    item = _fake_item(sections=[{"text": long_body}])
    text = build_embedding_text(item)
    # Title is "T", no description, so body fills almost the entire string.
    # 2000 chars of body + some glue characters.
    assert len(text) <= 2100
    assert "x" * 1500 in text


def test_build_embedding_text_handles_empty_inputs():
    """Empty sections + empty title should not crash; returns whatever's left."""
    item = _fake_item(title="", sections=None)
    assert build_embedding_text(item) == ""


def test_completed_or_liked_items_still_filtered_with_semantic_boost():
    """Semantic boost must NOT override the "already finished" filter —
    we shouldn't recommend an item the user already completed even if
    it's a perfect cosine match."""
    profile = UserProfile()
    item = _fake_item()
    profile.completed_ids.add(str(item.id))
    profile.semantic_boost = {str(item.id): 1.0}
    assert score_item(item, profile) == -1.0
