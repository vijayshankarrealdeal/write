"""Track 5 — Writing → FeedItem metadata auto-sync.

The handler under test is `update_writing` in `app.routers.writings`.
When an author PUTs a Writing whose FeedItem is already published, the
handler must re-call `upsert_feed_item_for_writing` so a typo fix or
cover swap reaches readers without an explicit republish. Draft cards
stay frozen, and price/visibility/byline/publisher carry over unchanged.

These tests stub the DB session and the `upsert_feed_item_for_writing`
function to keep the suite Postgres-free — the existing tests in this
package follow the same pattern (see `test_bookmarks.py`). The full
publish path itself has its own coverage in `app.feed_publish`; here
we pin the *trigger contract* of the writing PUT route.
"""
from __future__ import annotations

import sys
import types
import uuid
from datetime import UTC, datetime
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# Stub out `app.ai.embeddings` before any handler imports `app.feed_publish`
# — the real module pulls in the pydantic_ai writer agent, which may not be
# importable in the test environment (version drift unrelated to this
# track). The handler only needs the `schedule_embedding` symbol indirectly
# via `upsert_feed_item_for_writing`, and we mock the whole upsert anyway.
if "app.ai.embeddings" not in sys.modules:
    _stub = types.ModuleType("app.ai.embeddings")
    _stub.schedule_embedding = lambda *_a, **_k: None
    sys.modules["app.ai.embeddings"] = _stub

from app.routers import writings as writings_router  # noqa: E402
from app.schemas.writing import WritingUpdate  # noqa: E402


def _make_user(name: str = "Probe Author") -> SimpleNamespace:
    return SimpleNamespace(id=uuid.uuid4(), name=name)


def _make_writing(
    user_id: uuid.UUID,
    *,
    title: str = "Old Title",
    description: str = "Old description.",
    cover_image_path: str | None = "covers/old.png",
    cover_image_meta: dict | None = None,
    writing_type: str | None = "novel",
    target_word_count: int | None = 50_000,
) -> SimpleNamespace:
    now = datetime.now(tz=UTC)
    return SimpleNamespace(
        id=uuid.uuid4(),
        user_id=user_id,
        title=title,
        author="Probe Author",
        description=description,
        cover_image_path=cover_image_path,
        cover_image_meta=cover_image_meta or {"w": 800, "h": 1200},
        status=None,
        writing_type=writing_type,
        subtype=None,
        section_ids=[],
        target_word_count=target_word_count,
        target_deadline=None,
        label_meaning=None,
        label_names=None,
        page_layout=None,
        created_at=now,
        updated_at=now,
    )


def _make_feed_item(
    writing_id: uuid.UUID,
    author_id: uuid.UUID,
    *,
    title: str = "Old Title",
    description: str = "Old description.",
    image_url: str | None = "covers/old.png",
    image_meta: dict | None = None,
    genres: list[str] | None = None,
    writing_types: list[str] | None = None,
    tags: list[str] | None = None,
    is_draft: bool = False,
    visibility: str = "public",
    price_cents: int = 0,
    currency: str = "inr",
    author: str = "Probe Author",
) -> SimpleNamespace:
    return SimpleNamespace(
        id=uuid.uuid4(),
        writing_id=writing_id,
        author_id=author_id,
        title=title,
        description=description,
        image_url=image_url,
        image_meta=image_meta or {"w": 800, "h": 1200},
        genres=list(genres or []),
        writing_types=list(writing_types or []),
        tags=list(tags or []),
        is_draft=is_draft,
        visibility=visibility,
        price_cents=price_cents,
        currency=currency,
        author=author,
    )


def _scalar_result(value):
    """Build a fake SQLAlchemy `Result` whose `.scalar_one_or_none()`
    returns the given value. Matches the shape the handler expects."""
    result = MagicMock()
    result.scalar_one_or_none.return_value = value
    return result


def _build_db(
    *,
    writing: SimpleNamespace,
    feed_item: SimpleNamespace | None,
    publisher: SimpleNamespace | None,
) -> AsyncMock:
    """Stub `AsyncSession` whose `execute` returns the writing first
    (for `_get_user_writing`), then the feed_item lookup, and whose
    `get(User, ...)` returns the supplied publisher."""
    db = AsyncMock()
    # `_get_user_writing` -> select Writing -> scalar_one_or_none
    # then the auto-sync block -> select FeedItem -> scalar_one_or_none
    db.execute.side_effect = [
        _scalar_result(writing),
        _scalar_result(feed_item),
    ]
    db.get = AsyncMock(return_value=publisher)
    db.commit = AsyncMock()
    db.refresh = AsyncMock()
    return db


@pytest.mark.asyncio
async def test_update_without_feed_item_does_not_call_upsert():
    """Editing a writing that was never published must not magically
    materialise a feed card. Otherwise unpublished drafts would leak
    onto the public feed the moment the author fixes a typo."""
    user = _make_user()
    writing = _make_writing(user.id)
    db = _build_db(writing=writing, feed_item=None, publisher=None)

    with patch(
        "app.feed_publish.upsert_feed_item_for_writing", new=AsyncMock()
    ) as upsert, patch.object(
        writings_router.hub, "broadcast_writing", new=AsyncMock()
    ):
        await writings_router.update_writing(
            writing_id=writing.id,
            data=WritingUpdate(title="New Title"),
            user=user,
            db=db,
            op_id=None,
        )

    upsert.assert_not_awaited()


@pytest.mark.asyncio
async def test_update_title_with_published_feed_item_syncs_title():
    """The headline use case — fix a typo on the draft, see the
    correction on the published card without re-opening the publish
    dialog. `upsert_feed_item_for_writing` should be invoked with the
    writing's new title."""
    user = _make_user()
    writing = _make_writing(user.id, title="Old Title")
    publisher = _make_user("Publisher Identity")
    feed_item = _make_feed_item(
        writing.id, author_id=publisher.id, title="Old Title", is_draft=False
    )
    db = _build_db(writing=writing, feed_item=feed_item, publisher=publisher)

    new_title = "Corrected Title"
    with patch(
        "app.feed_publish.upsert_feed_item_for_writing", new=AsyncMock()
    ) as upsert, patch.object(
        writings_router.hub, "broadcast_writing", new=AsyncMock()
    ):
        await writings_router.update_writing(
            writing_id=writing.id,
            data=WritingUpdate(title=new_title),
            user=user,
            db=db,
            op_id=None,
        )

    upsert.assert_awaited_once()
    kwargs = upsert.await_args.kwargs
    assert kwargs["writing_id"] == writing.id
    assert kwargs["publisher"] is publisher
    assert kwargs["title"] == new_title


@pytest.mark.asyncio
async def test_update_description_on_draft_feed_item_does_not_sync():
    """Drafts are frozen — an in-progress publish (still toggled
    `is_draft=True`) must not silently inherit subsequent writing edits.
    The author owns the explicit publish transition."""
    user = _make_user()
    writing = _make_writing(user.id, description="Old description.")
    publisher = _make_user("Publisher Identity")
    feed_item = _make_feed_item(
        writing.id,
        author_id=publisher.id,
        description="Old description.",
        is_draft=True,
    )
    db = _build_db(writing=writing, feed_item=feed_item, publisher=publisher)

    with patch(
        "app.feed_publish.upsert_feed_item_for_writing", new=AsyncMock()
    ) as upsert, patch.object(
        writings_router.hub, "broadcast_writing", new=AsyncMock()
    ):
        await writings_router.update_writing(
            writing_id=writing.id,
            data=WritingUpdate(description="New description."),
            user=user,
            db=db,
            op_id=None,
        )

    upsert.assert_not_awaited()


@pytest.mark.asyncio
async def test_update_only_non_synced_field_skips_feed_lookup():
    """`target_word_count` is private project metadata — it has no
    presence on the public FeedItem. We don't even hit the feed table
    lookup, let alone call upsert."""
    user = _make_user()
    writing = _make_writing(user.id, target_word_count=50_000)
    # Note: only ONE execute call expected (the `_get_user_writing`
    # select). If the auto-sync block fires it'll exhaust the side_effect
    # list and raise StopIteration, which the test would surface.
    db = AsyncMock()
    db.execute.side_effect = [_scalar_result(writing)]
    db.get = AsyncMock()
    db.commit = AsyncMock()
    db.refresh = AsyncMock()

    with patch(
        "app.feed_publish.upsert_feed_item_for_writing", new=AsyncMock()
    ) as upsert, patch.object(
        writings_router.hub, "broadcast_writing", new=AsyncMock()
    ):
        await writings_router.update_writing(
            writing_id=writing.id,
            data=WritingUpdate(target_word_count=80_000),
            user=user,
            db=db,
            op_id=None,
        )

    upsert.assert_not_awaited()
    # Only the writing lookup ran — no FeedItem lookup, no publisher fetch.
    assert db.execute.await_count == 1
    db.get.assert_not_awaited()


@pytest.mark.asyncio
async def test_title_sync_preserves_price_visibility_byline_publisher():
    """The whole reason we accept the explicit list of fields above:
    metadata edits must not silently change the publish-time decisions
    the author made (price, visibility, the byline that may differ from
    the publishing user, and the publisher identity itself). Those stay
    pinned to whatever the FeedItem already had."""
    user = _make_user("Author Account")
    writing = _make_writing(user.id, title="Old Title")
    # Ingest-style: publisher account differs from the byline ("Jane Austen"
    # uploaded under the editorial "inkspace" identity). Both must survive
    # a metadata sync untouched.
    publisher = _make_user("inkspace")
    feed_item = _make_feed_item(
        writing.id,
        author_id=publisher.id,
        title="Old Title",
        is_draft=False,
        visibility="private",
        price_cents=49900,
        currency="inr",
        author="Jane Austen",
        genres=["literary"],
        tags=["classic", "victorian"],
        writing_types=["novel"],
    )
    db = _build_db(writing=writing, feed_item=feed_item, publisher=publisher)

    with patch(
        "app.feed_publish.upsert_feed_item_for_writing", new=AsyncMock()
    ) as upsert, patch.object(
        writings_router.hub, "broadcast_writing", new=AsyncMock()
    ):
        await writings_router.update_writing(
            writing_id=writing.id,
            data=WritingUpdate(title="Pride and Prejudice"),
            user=user,
            db=db,
            op_id=None,
        )

    upsert.assert_awaited_once()
    kwargs = upsert.await_args.kwargs
    # Synced from writing.
    assert kwargs["title"] == "Pride and Prejudice"
    # Preserved from feed_item — these are author publish-time decisions.
    assert kwargs["price_cents"] == 49900
    assert kwargs["currency"] == "inr"
    assert kwargs["visibility"] == "private"
    assert kwargs["author_display"] == "Jane Austen"
    assert kwargs["publisher"] is publisher
    assert kwargs["is_draft"] is False
    # Genres/tags don't exist on the Writing model so they're carried
    # over from the existing FeedItem unchanged.
    assert kwargs["genres"] == ["literary"]
    assert kwargs["tags"] == ["classic", "victorian"]


@pytest.mark.asyncio
async def test_cover_swap_propagates_image_url_and_meta():
    """Cover art is the most visible metadata after the title — confirm
    `cover_image_path` and `cover_image_meta` both reach the published
    card under their feed-side names (`image_url`, `image_meta`)."""
    user = _make_user()
    writing = _make_writing(
        user.id,
        cover_image_path="covers/old.png",
        cover_image_meta={"w": 800, "h": 1200},
    )
    publisher = _make_user("Publisher Identity")
    feed_item = _make_feed_item(
        writing.id, author_id=publisher.id, is_draft=False
    )
    db = _build_db(writing=writing, feed_item=feed_item, publisher=publisher)

    new_cover = "covers/new.png"
    new_meta = {"w": 1024, "h": 1536, "palette": ["#aabbcc"]}
    with patch(
        "app.feed_publish.upsert_feed_item_for_writing", new=AsyncMock()
    ) as upsert, patch.object(
        writings_router.hub, "broadcast_writing", new=AsyncMock()
    ):
        await writings_router.update_writing(
            writing_id=writing.id,
            data=WritingUpdate(
                cover_image_path=new_cover, cover_image_meta=new_meta
            ),
            user=user,
            db=db,
            op_id=None,
        )

    upsert.assert_awaited_once()
    kwargs = upsert.await_args.kwargs
    assert kwargs["image_url"] == new_cover
    assert kwargs["image_meta"] == new_meta


@pytest.mark.asyncio
async def test_writing_type_change_propagates_as_singleton_list():
    """FeedItem stores writing_types as a list (a card may live in
    multiple buckets), but Writing has a single `writing_type` column.
    The sync wraps the scalar in a 1-element list — and an empty / null
    writing_type collapses to an empty list, not `[None]`."""
    user = _make_user()
    writing = _make_writing(user.id, writing_type="novel")
    publisher = _make_user("Publisher Identity")
    feed_item = _make_feed_item(
        writing.id,
        author_id=publisher.id,
        is_draft=False,
        writing_types=["novel"],
    )
    db = _build_db(writing=writing, feed_item=feed_item, publisher=publisher)

    with patch(
        "app.feed_publish.upsert_feed_item_for_writing", new=AsyncMock()
    ) as upsert, patch.object(
        writings_router.hub, "broadcast_writing", new=AsyncMock()
    ):
        await writings_router.update_writing(
            writing_id=writing.id,
            data=WritingUpdate(writing_type="short_story"),
            user=user,
            db=db,
            op_id=None,
        )

    upsert.assert_awaited_once()
    assert upsert.await_args.kwargs["writing_types"] == ["short_story"]
