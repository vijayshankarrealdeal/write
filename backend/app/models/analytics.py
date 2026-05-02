import uuid
from datetime import datetime

from sqlalchemy import DateTime, Float, ForeignKey, Index, Integer, String, Text, text
from sqlalchemy.dialects.postgresql import INET, JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDMixin


class AnalyticsEvent(Base, UUIDMixin):
    """User-behaviour event log.

    Designed around the question "what did this user do, in what order?".
    `user_id` is the primary lens; `client_id` is the stable anonymous
    identity used to stitch pre-auth events to the user once they sign in.
    Per-session funnels use `session_id`. The `properties` JSONB carries
    event-specific context (post_id, target_user_id, search_query, etc.)
    and has a GIN index so `properties @> '{"post_id": "..."}'` is fast.

    Never store passwords, tokens, or PII in `properties` — the analytics
    service strips them client-side, but the contract bears repeating.
    """

    __tablename__ = "analytics_events"

    user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    client_id: Mapped[str] = mapped_column(String(64), nullable=False)
    session_id: Mapped[str] = mapped_column(String(64), nullable=False)
    event_name: Mapped[str] = mapped_column(String(80), nullable=False)
    screen: Mapped[str | None] = mapped_column(String(120), nullable=True)
    # view / click / submit / success / fail / impression / etc.
    action: Mapped[str | None] = mapped_column(String(20), nullable=True)
    entity_type: Mapped[str | None] = mapped_column(String(40), nullable=True)
    entity_id: Mapped[str | None] = mapped_column(String(80), nullable=True)
    source_screen: Mapped[str | None] = mapped_column(String(120), nullable=True)
    duration_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    properties: Mapped[dict] = mapped_column(JSONB, nullable=False, server_default=text("'{}'::jsonb"))
    client_ts: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    server_ts: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False
    )
    user_agent: Mapped[str | None] = mapped_column(String(500), nullable=True)
    ip: Mapped[str | None] = mapped_column(INET, nullable=True)

    __table_args__ = (
        Index("ix_analytics_events_user_server_ts", "user_id", "server_ts"),
        Index("ix_analytics_events_event_server_ts", "event_name", "server_ts"),
        Index("ix_analytics_events_client_server_ts", "client_id", "server_ts"),
        Index("ix_analytics_events_session_server_ts", "session_id", "server_ts"),
        Index(
            "ix_analytics_events_properties_gin",
            "properties",
            postgresql_using="gin",
        ),
    )


class PageVisit(Base, UUIDMixin):
    __tablename__ = "page_visits"

    user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    page: Mapped[str] = mapped_column(String(500), nullable=False)
    referrer: Mapped[str | None] = mapped_column(String(500), nullable=True)
    session_id: Mapped[str | None] = mapped_column(String(100), nullable=True)
    device: Mapped[str | None] = mapped_column(String(200), nullable=True)
    platform: Mapped[str | None] = mapped_column(String(50), nullable=True)
    duration_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    visited_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()")
    )


class CrashReport(Base, UUIDMixin):
    __tablename__ = "crash_reports"

    user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    error_type: Mapped[str] = mapped_column(String(200), nullable=False)
    error_message: Mapped[str] = mapped_column(Text, nullable=False)
    stack_trace: Mapped[str | None] = mapped_column(Text, nullable=True)
    page: Mapped[str | None] = mapped_column(String(500), nullable=True)
    device: Mapped[str | None] = mapped_column(String(200), nullable=True)
    platform: Mapped[str | None] = mapped_column(String(50), nullable=True)
    app_version: Mapped[str | None] = mapped_column(String(50), nullable=True)
    resolved: Mapped[bool] = mapped_column(default=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()")
    )


class RecommendationEvent(Base, UUIDMixin):
    """Tracks impressions and clicks on recommended feed items.

    Without this table, we have no way to measure whether the recommendation
    engine is doing its job — CTR, dwell, A/B comparisons all need it.
    """

    __tablename__ = "recommendation_events"

    user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    feed_item_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("feed_items.id", ondelete="CASCADE"), nullable=False
    )
    # 'impression' = card was shown; 'click' = user opened the post.
    event_type: Mapped[str] = mapped_column(String(20), nullable=False)
    # 1-based slot the item occupied in the recommendation list.
    position: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # The score the engine assigned at serve time (so we can correlate score → CTR).
    score: Mapped[float | None] = mapped_column(Float, nullable=True)
    # 'engine' (content-based score), 'cold_start', or 'llm_rerank'.
    source: Mapped[str | None] = mapped_column(String(30), nullable=True)
    # Opaque request id grouping all impressions/clicks from one feed render.
    session_id: Mapped[str | None] = mapped_column(String(100), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()")
    )

    __table_args__ = (
        Index("ix_rec_events_user_created", "user_id", "created_at"),
        Index("ix_rec_events_item_type", "feed_item_id", "event_type"),
    )


class AppLog(Base, UUIDMixin):
    __tablename__ = "app_logs"

    level: Mapped[str] = mapped_column(String(20), nullable=False)  # info, warn, error
    source: Mapped[str] = mapped_column(String(20), nullable=False)  # backend, frontend
    env: Mapped[str | None] = mapped_column(String(10), nullable=True)  # dev, prod
    logger: Mapped[str | None] = mapped_column(String(200), nullable=True)
    message: Mapped[str] = mapped_column(Text, nullable=False)
    details: Mapped[str | None] = mapped_column(Text, nullable=True)
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    request_path: Mapped[str | None] = mapped_column(String(500), nullable=True)
    request_method: Mapped[str | None] = mapped_column(String(10), nullable=True)
    status_code: Mapped[int | None] = mapped_column(Integer, nullable=True)
    duration_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()")
    )
