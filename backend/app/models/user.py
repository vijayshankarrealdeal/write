import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Index, String, Text, func
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UUIDMixin


class User(UUIDMixin, Base):
    __tablename__ = "users"

    email: Mapped[str] = mapped_column(String(320), unique=True, nullable=False)
    name: Mapped[str | None] = mapped_column(String(255))
    password_hash: Mapped[str | None] = mapped_column(Text)
    photo_url: Mapped[str | None] = mapped_column(Text)
    photo_meta: Mapped[dict | None] = mapped_column(JSONB)
    onboarding_complete: Mapped[bool] = mapped_column(Boolean, default=False)
    onboarding_data: Mapped[dict | None] = mapped_column(JSONB)

    # Public profile copy. `bio` is free-text shown on the author profile
    # page; `social_links` is a flat map of well-known platform → URL/
    # handle (`website`, `twitter`, `instagram`, `github`, `linkedin`).
    # Both are visible to anyone who can see the user, so write-side
    # length / sanity checks live in the schema layer.
    bio: Mapped[str | None] = mapped_column(Text)
    social_links: Mapped[dict | None] = mapped_column(JSONB)

    likes: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    reading_list: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    saved_posts: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    favorite_posts: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    section_bookmarks: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)

    # Razorpay Linked Account (Route). Populated after the author taps
    # "Set up payouts" — the backend creates the account and requests the
    # Route product, then hands the author the activation form link to
    # complete KYC. `razorpay_charges_enabled` mirrors the linked
    # account's activation state and only flips true once Razorpay has
    # cleared KYC, at which point Route transfers from captured payments
    # land in the author's balance (minus our platform fee). Both fields
    # are null/false for readers who never opt into selling.
    razorpay_account_id: Mapped[str | None] = mapped_column(String(64))
    razorpay_charges_enabled: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )

    # Razorpay reader-side subscription (₹199/month). The customer id is
    # minted lazily on the user's first Subscribe tap and reused for
    # every subsequent subscription so Razorpay sees one customer per
    # InkSpaceX account. `active_subscription_id` is a denormalised
    # pointer to the current/most-recent `subscriptions` row — the
    # per-request "is this user a paying reader?" check is a single
    # row read on `users`, no join. NULLed when the subscription ends
    # (cancelled / completed / halted-and-abandoned); set to the new
    # row id when they resubscribe. `subscription_status` mirrors the
    # latest `subscriptions.status` for the same hot-path reason. The
    # FK is declared with `use_alter=True` because `subscriptions` in
    # turn references `users.id`, so neither table can be created
    # first without a deferred constraint.
    razorpay_customer_id: Mapped[str | None] = mapped_column(String(64))
    active_subscription_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey(
            "subscriptions.id",
            use_alter=True,
            name="fk_users_active_subscription",
        ),
    )
    subscription_status: Mapped[str | None] = mapped_column(String(32))

    # ISO 3166-1 alpha-2 country code (`IN`, `US`, `GB`, ...) resolved
    # from the request IP on the first authenticated call after signup.
    # Used by the subscriptions router to pick a payment processor (Razorpay
    # for IN, Stripe for elsewhere — once the second processor lands) and
    # surfaced on the admin dashboard. Null while unresolved (new signup,
    # or the IP→country call hasn't run / failed). See
    # `app.geo.resolve_country_code` for the resolution path.
    country_code: Mapped[str | None] = mapped_column(String(2))

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    # Relationships
    writings: Mapped[list["Writing"]] = relationship(back_populates="user", cascade="all, delete-orphan")  # noqa: F821
    feed_items: Mapped[list["FeedItem"]] = relationship(back_populates="author_user")  # noqa: F821
    bookshelves: Mapped[list["Bookshelf"]] = relationship(back_populates="user", cascade="all, delete-orphan")  # noqa: F821
    highlights: Mapped[list["Highlight"]] = relationship(back_populates="user", cascade="all, delete-orphan")  # noqa: F821
    reading_progress: Mapped[list["ReadingProgress"]] = relationship(back_populates="user", cascade="all, delete-orphan")  # noqa: F821
    bookmarks: Mapped[list["Bookmark"]] = relationship(back_populates="user", cascade="all, delete-orphan")  # noqa: F821
    author_bookmarks: Mapped[list["AuthorBookmark"]] = relationship(back_populates="user", cascade="all, delete-orphan")  # noqa: F821
    subscriptions: Mapped[list["Subscription"]] = relationship(back_populates="user", cascade="all, delete-orphan", foreign_keys="Subscription.user_id")  # noqa: F821

    __table_args__ = (
        # Collaborative filtering pivots on "find users whose `likes` array
        # overlaps with mine." Without GIN, that's a full table scan.
        Index("ix_users_likes_gin", "likes", postgresql_using="gin"),
    )
