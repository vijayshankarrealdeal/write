"""Email signups from the public landing page (`/land`).

A standalone table — these aren't users yet, just leads we collect
before they install the app. Kept separate from `users` so a marketing
list can be exported without leaking account state, and so a signup
can't accidentally collide with a real account row.
"""
from datetime import datetime

from sqlalchemy import DateTime, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDMixin


class EarlyTester(UUIDMixin, Base):
    __tablename__ = "early_testers"

    # Always stored lower-cased on write so the unique constraint also
    # serves case-insensitive dedup without a functional index.
    email: Mapped[str] = mapped_column(String(320), unique=True, nullable=False)
    source: Mapped[str | None] = mapped_column(String(64))
    user_agent: Mapped[str | None] = mapped_column(String(512))
    ip: Mapped[str | None] = mapped_column(String(64))

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), index=True
    )
