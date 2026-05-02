"""Visibility predicate for feed items.

Centralises the audience-gate SQL clause so every route, recommender
candidate query, and admin tool that surfaces FeedItem rows to a viewer
applies the same rule.

The rule (Instagram-style per-writing privacy):

    feed_item.visibility = 'public'
    OR feed_item.author_id = :viewer_id
    OR EXISTS (
        SELECT 1 FROM follows
        WHERE follower_id = :viewer_id
          AND followee_id = feed_item.author_id
          AND status = 'approved'
    )

`is_draft` is intentionally NOT bundled in: some endpoints (e.g.
`/api/feed/by-author?include_drafts=true`) opt into showing drafts to the
author themselves, so each call site keeps its own draft gate.
"""
from __future__ import annotations

import uuid

from sqlalchemy import and_, or_, select

from app.models.feed_item import FeedItem
from app.models.follow import Follow


def visibility_clause(viewer_id: uuid.UUID, *, item=FeedItem):
    """Return a SQLAlchemy clause that filters `item` rows the viewer can read.

    Pass an aliased model (`aliased(FeedItem)`) as `item` when the query
    references multiple FeedItem aliases (e.g. cursor pagination joins).
    """
    # The EXISTS subquery references `item.author_id` from the outer
    # query — call `.correlate(item)` so SQLAlchemy doesn't add `item`
    # to the subquery's own FROM list (which would cross-join and make
    # the predicate always true).
    approved_follow = (
        select(Follow.id)
        .where(
            Follow.follower_id == viewer_id,
            Follow.followee_id == item.author_id,
            Follow.status == "approved",
        )
        .correlate(item)
        .exists()
    )
    return or_(
        item.visibility == "public",
        item.author_id == viewer_id,
        approved_follow,
    )


def public_feed_clause(viewer_id: uuid.UUID, *, item=FeedItem):
    """Combined gate for the public-feed read paths: not-draft AND visible.

    Most listing endpoints (`/api/feed/`, `/by-tag`, `/by-genre`, `/search`,
    recommender candidate pool) want this combined predicate. Endpoints that
    show drafts to the author (e.g. `by-author?include_drafts=true`) should
    use `visibility_clause` directly and apply their own draft logic.
    """
    return and_(item.is_draft.is_(False), visibility_clause(viewer_id, item=item))


__all__ = ["visibility_clause", "public_feed_clause"]
