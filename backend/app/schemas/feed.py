from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class CharacterPayload(BaseModel):
    """One entry in the book's cast list, posted alongside the feed
    item at publish time. The handler upserts `book_characters` rows
    keyed on (writing_id, name)."""
    name: str
    appearance: str
    image_url: str | None = None
    image_meta: dict | None = None
    sort_order: int = 0


class FeedItemCreate(BaseModel):
    title: str
    description: str | None = None
    image_url: str | None = None
    image_meta: dict | None = None
    genres: list[str] = []
    writing_types: list[str] = []
    tags: list[str] = []
    is_draft: bool = True
    visibility: str = "public"
    # The author's curated chapter selection at publish time. Section
    # ids in this list get `is_published=True`; ids omitted (but still
    # present in the writing) get `is_published=False`. Adding /
    # removing a chapter from the public list requires a republish;
    # body edits to already-published sections propagate live.
    # `None` means "leave per-section publish flags alone" (used on
    # metadata-only republishes — rename, retag, draft toggle).
    published_section_ids: list[UUID] | None = None
    # Per-chapter free-preview gate for paid books. `is_free_preview`
    # flips True for ids in this list, False for everything else under
    # the writing. `None` means "leave the flags alone" (mirrors
    # `published_section_ids`).
    free_preview_section_ids: list[UUID] | None = None
    # Price in the smallest currency unit (paise / cents). 0 = free.
    # Validated server-side: a positive price requires the calling
    # author to have completed Razorpay linked-account onboarding.
    price_cents: int | None = None
    currency: str | None = None
    # Accepted-but-ignored — old clients still send chapter bodies in
    # the publish payload from cached state. Sections live in the
    # `sections` table now; the publish path discards this field.
    sections: list[dict] | None = None
    # Source writing this card was published from. Set when the user
    # publishes a draft from the editor, so the DB-level CASCADE drops
    # the card if the writing is later deleted.
    writing_id: UUID | None = None
    # Cast list — populated by the ingest pipeline (scout character
    # bible + character_sheets phase). `None` leaves the existing cast
    # alone (metadata-only republish); empty list wipes it; a list
    # replaces it. Authors editing a book in the Flutter editor never
    # send this; only the studio's remote_publish does, after uploading
    # each portrait through /api/upload/editor.
    characters: list[CharacterPayload] | None = None


class FeedItemUpdate(BaseModel):
    title: str | None = None
    description: str | None = None
    image_url: str | None = None
    image_meta: dict | None = None
    genres: list[str] | None = None
    writing_types: list[str] | None = None
    tags: list[str] | None = None
    is_draft: bool | None = None
    visibility: str | None = None
    # See FeedItemCreate.published_section_ids — applies on update too.
    published_section_ids: list[UUID] | None = None
    free_preview_section_ids: list[UUID] | None = None
    price_cents: int | None = None
    currency: str | None = None
    # Accepted-but-ignored — see FeedItemCreate.sections.
    sections: list[dict] | None = None


class FeedItemResponse(BaseModel):
    id: UUID
    title: str | None
    author: str | None
    author_id: UUID
    writing_id: UUID | None = None
    description: str | None
    image_url: str | None
    image_meta: dict | None = None
    genres: list[str]
    writing_types: list[str]
    tags: list[str]
    likes_count: int
    comments_count: int
    is_draft: bool
    visibility: str = "public"
    # Pricing surface. `price_cents == 0` is the historical default and
    # means "free, no gate". `purchased` is computed per-request: True
    # for the author, True for users with a Purchase row, False
    # otherwise. The chip / Buy button on the feed card use it directly.
    price_cents: int = 0
    currency: str = "usd"
    purchased: bool = False
    # Listings (`/`, `/by-tag`, `/by-genre`, `/by-author`, `/search`,
    # `/home`) leave this null. The detail endpoint
    # (`GET /api/feed/{id}`) fills it with ordered chapter stubs:
    # `[{section_id, title, updated_at, _has_image, is_free_preview,
    # _lazy: True}, ...]`. Bodies are fetched per-section via
    # `/api/feed/{id}/sections/{section_id}` — keeps the response
    # bounded for thousand-chapter books.
    sections: list[dict] | None = None
    # Estimated reading time in minutes for the book's published
    # sections, computed server-side from the JSON text inserts in
    # each section's Quill delta. Filled only by the detail endpoint
    # (`GET /api/feed/{id}`) — listing endpoints leave it null so the
    # client falls back to a cheap in-memory estimate. The number is
    # already clamped to >= 1.
    reading_minutes: int | None = None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class HomeRail(BaseModel):
    """One shelf in the composed home feed (e.g. 'Trending Now',
    'Continue Reading'). The home composer guarantees no item appears
    in more than one rail in a single response."""

    rail_id: str
    title: str
    items: list[FeedItemResponse]


class FacetEntry(BaseModel):
    """One bucket in the facet sidebar — a (label, count) pair."""

    value: str
    count: int


class FacetResponse(BaseModel):
    """Top genres / tags / writing_types served by `/api/feed/facets`."""

    genres: list[FacetEntry]
    tags: list[FacetEntry]
    writing_types: list[FacetEntry]


class CommentCreate(BaseModel):
    text: str
    rating: float | None = None


class CommentResponse(BaseModel):
    id: UUID
    feed_item_id: UUID
    author_id: UUID
    author_name: str | None
    author_photo_url: str | None
    author_photo_meta: dict | None = None
    text: str
    rating: float | None
    created_at: datetime

    model_config = {"from_attributes": True}
