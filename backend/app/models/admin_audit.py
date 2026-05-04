"""Admin-action audit log.

Every privileged mutation that runs from the admin dashboard writes a
row here so the operations team can answer "who did what and when?"
weeks after the fact. Examples: dictionary merges, global word
removals, forced password resets, table truncations.

Kept deliberately simple — `action` is a short verb-style key, `target`
is a free-form JSONB blob with action-specific context (accepted/rejected
counts, the row PK that was touched, etc.). Append-only; never updated.
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, String, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDMixin


class AdminAudit(UUIDMixin, Base):
    __tablename__ = "admin_audit"

    # The admin username from settings.admin_username at the time of the
    # action. Sourced from the verified session token, not the request
    # body, so a forged payload can't spoof someone else.
    admin_username: Mapped[str] = mapped_column(String(80), nullable=False)
    # Short verb-style key — e.g. "dictionary.merge",
    # "dictionary.word.remove", "user.password.reset". Indexed so the
    # admin viewer can filter by action.
    action: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    # JSONB context: accepted/rejected counts, target row id, the diff
    # that was applied — whatever the action's caller wanted to record.
    target: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
        index=True,
    )
