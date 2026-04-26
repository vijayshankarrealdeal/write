"""Phase 3 (P2): bookmarks table + reading_progress anchor columns.

Revision ID: 20260426_03
Revises: 20260426_02
Create Date: 2026-04-26
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "20260426_03"
down_revision = "20260426_02"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # reading_progress: paragraph-precise resume.
    op.add_column(
        "reading_progress",
        sa.Column("last_section_id", sa.String(length=64), nullable=True),
    )
    op.add_column(
        "reading_progress",
        sa.Column(
            "last_anchor",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=True,
        ),
    )
    op.create_index(
        "ix_reading_progress_user_last_read",
        "reading_progress",
        ["user_id", "last_read_at"],
    )

    # bookmarks table.
    op.create_table(
        "bookmarks",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            server_default=sa.text("gen_random_uuid()"),
            primary_key=True,
        ),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "feed_item_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("feed_items.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("section_id", sa.String(length=64), nullable=True),
        sa.Column(
            "section_index",
            sa.Integer(),
            nullable=False,
            server_default="0",
        ),
        sa.Column(
            "anchor",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
        ),
        sa.Column("label", sa.String(length=120), nullable=True),
        sa.Column(
            "color",
            sa.String(length=10),
            nullable=False,
            server_default="#FFB300",
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.UniqueConstraint(
            "user_id",
            "feed_item_id",
            "section_index",
            "anchor",
            name="uq_bookmark_anchor",
        ),
    )
    op.create_index(
        "ix_bookmarks_user_feed_item",
        "bookmarks",
        ["user_id", "feed_item_id"],
    )
    op.create_index(
        "ix_bookmarks_user_updated",
        "bookmarks",
        ["user_id", "updated_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_bookmarks_user_updated", table_name="bookmarks")
    op.drop_index("ix_bookmarks_user_feed_item", table_name="bookmarks")
    op.drop_table("bookmarks")
    op.drop_index(
        "ix_reading_progress_user_last_read",
        table_name="reading_progress",
    )
    op.drop_column("reading_progress", "last_anchor")
    op.drop_column("reading_progress", "last_section_id")
