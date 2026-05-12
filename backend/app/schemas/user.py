from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field


# Keys allowed in the `social_links` JSONB blob. Anything outside this
# set is dropped on write so the client UI can render a fixed set of
# platform icons without having to handle arbitrary keys.
SOCIAL_LINK_KEYS: frozenset[str] = frozenset(
    {"website", "twitter", "instagram", "linkedin", "goodreads"}
)
# Per-value cap. Generous enough for a long URL but small enough that an
# attacker can't smuggle a payload into the public profile JSONB.
_MAX_SOCIAL_VALUE_LEN = 500
# Bio cap — a few paragraphs, not a chapter. Mirrors the same posture
# Twitter / GitHub take on free-text profile fields.
_MAX_BIO_LEN = 1000


def normalize_social_links(value: dict | None) -> dict | None:
    """Strip unknown keys, drop empty/oversized values, and trim
    whitespace. Returns None if the resulting dict is empty so we don't
    persist `{}` for users who clear all their links."""
    if not value:
        return None
    out: dict[str, str] = {}
    for key in SOCIAL_LINK_KEYS:
        raw = value.get(key)
        if not isinstance(raw, str):
            continue
        cleaned = raw.strip()
        if not cleaned:
            continue
        if len(cleaned) > _MAX_SOCIAL_VALUE_LEN:
            cleaned = cleaned[:_MAX_SOCIAL_VALUE_LEN]
        out[key] = cleaned
    return out or None


def normalize_bio(value: str | None) -> str | None:
    if value is None:
        return None
    cleaned = value.strip()
    if not cleaned:
        return None
    if len(cleaned) > _MAX_BIO_LEN:
        cleaned = cleaned[:_MAX_BIO_LEN]
    return cleaned


class UserResponse(BaseModel):
    id: UUID
    email: str
    name: str | None
    photo_url: str | None
    photo_meta: dict | None = None
    onboarding_complete: bool
    onboarding_data: dict | None
    bio: str | None = None
    social_links: dict | None = None
    likes: list[str]
    reading_list: list[str]
    saved_posts: list[str]
    favorite_posts: list[str]
    section_bookmarks: list[str]
    # ISO 3166-1 alpha-2 country code, resolved server-side from the
    # request IP on first authenticated call. Null while the resolution
    # is in flight or has failed. Surfaced so the Flutter client and
    # admin dashboard can both read the same source of truth.
    country_code: str | None = None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class UserUpdate(BaseModel):
    name: str | None = None
    photo_url: str | None = None
    photo_meta: dict | None = None
    onboarding_complete: bool | None = None
    onboarding_data: dict | None = None
    # `bio` and `social_links` are normalized in the router (length cap,
    # whitespace, dropping unknown keys) before they hit the model.
    bio: str | None = Field(default=None, max_length=_MAX_BIO_LEN * 2)
    social_links: dict | None = None


class ListUpdateRequest(BaseModel):
    """For adding/removing items from user lists (likes, saved_posts, etc.)."""
    action: str  # "add" or "remove"
    item_id: str
