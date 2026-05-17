from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel


class ReadingProgressUpdate(BaseModel):
    scroll_position: float | None = None
    completed: bool | None = None
    last_section_id: str | None = None
    last_anchor: dict | None = None


class ReadingProgressResponse(BaseModel):
    id: UUID
    user_id: UUID
    feed_item_id: UUID
    scroll_position: float | None
    last_read_at: datetime | None
    completed: bool
    # Set the first time ``completed`` flips false → true. Drives the
    # "Finished" Library tab and the "you finished this on X" copy.
    finished_at: datetime | None = None
    last_section_id: str | None = None
    last_anchor: dict | None = None
    created_at: datetime | None = None

    model_config = {"from_attributes": True}


class ContinueReadingItem(BaseModel):
    """Joined view used by the home rail — feed item metadata + the user's
    last position. Image/title come straight from `feed_items` so the rail
    can render without an extra round trip."""

    feed_item_id: UUID
    title: str | None
    author: str | None
    image_url: str | None
    image_meta: dict | None = None
    scroll_position: float | None
    last_read_at: datetime | None
    last_section_id: str | None = None
    last_anchor: dict | None = None
    completed: bool

    model_config = {"from_attributes": True}


# Library "label" maps to a per-book state computed from reading_progress
# and bookshelves. The Flutter side renders each as a small coloured chip
# using the inkspacex tier palette so badges and labels share a vocabulary:
#   reading   #F59E0B amber    — completed=false AND last_read_at IS NOT NULL
#   finished  #22C55E green    — completed=true
#   saved     #3B82F6 blue     — row in bookshelves only (no progress)
#   abandoned #94A3B8 slate    — heuristic, not enforced server-side today
LibraryLabel = Literal["reading", "saved", "finished", "abandoned", "all"]


class LibraryBook(BaseModel):
    """One row in the user's Library — what the grid card needs to render.

    Aggregated server-side so the client can paint a card with cover,
    title, author, label chip, and resume target in a single request.
    """

    feed_item_id: UUID
    writing_id: UUID | None = None
    title: str | None
    author: str | None
    image_url: str | None
    image_meta: dict | None = None
    label: Literal["reading", "saved", "finished", "abandoned"]
    # Reading progress fields — None for `saved` rows that the user
    # has never opened.
    scroll_position: float | None = None
    last_read_at: datetime | None = None
    last_section_id: str | None = None
    last_anchor: dict | None = None
    finished_at: datetime | None = None
    # Bookshelf metadata — populated for `saved` rows (and may also be
    # set on reading/finished books that the user explicitly shelved).
    shelf_id: UUID | None = None
    shelf_name: str | None = None


class LibraryCounts(BaseModel):
    """One row per label for the tab badges. ``all`` is the union."""

    reading: int
    saved: int
    finished: int
    abandoned: int
    all: int
