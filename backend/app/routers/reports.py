"""User reports + admin moderation queue.

Two surfaces:
- `/api/reports`: authenticated users submit reports against stories,
  comments, users, or chat messages they can see.
- `/api/admin/reports`: admin-only listing + status updates, mirrors
  the auth pattern used by `app.routers.admin` (token query param).
"""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.chat import ChatMessage, Conversation
from app.models.comment import Comment
from app.models.feed_item import FeedItem
from app.models.report import REPORT_STATUSES, Report
from app.models.user import User
from app.routers.admin import _verify_admin
from app.schemas.report import ReportCreate, ReportResponse, ReportUpdate

router = APIRouter(tags=["reports"])


# ── User-facing: submit a report ───────────────────────────────────────────

@router.post("/api/reports", status_code=201)
async def create_report(
    payload: ReportCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Submit a report. Validates the target exists and snapshots its
    text so the admin queue stays useful even if the target is deleted
    before review.
    """
    snapshot, target_author_id = await _resolve_target(
        db, user, payload.target_type, payload.target_id
    )

    # Soft-dedupe: if the same user already filed a pending report on
    # the same target, don't create a duplicate row — return 200 so
    # the client treats it as a successful submission.
    existing_q = await db.execute(
        select(Report).where(
            Report.reporter_id == user.id,
            Report.target_type == payload.target_type,
            Report.target_id == payload.target_id,
            Report.status == "pending",
        )
    )
    if existing_q.scalar_one_or_none() is not None:
        return {"status": "ok", "duplicate": True}

    report = Report(
        reporter_id=user.id,
        target_type=payload.target_type,
        target_id=payload.target_id,
        target_author_id=target_author_id,
        reason=payload.reason,
        note=(payload.note or None),
        snapshot=snapshot,
        source="user",
        status="pending",
    )
    db.add(report)
    await db.commit()
    await db.refresh(report)
    return {"status": "ok", "id": str(report.id)}


# ── Admin-facing: list + update ────────────────────────────────────────────

@router.get("/api/admin/reports")
async def list_reports(
    page: int = Query(1, ge=1),
    per_page: int = Query(25, ge=1, le=100),
    status: str | None = Query(None),
    target_type: str | None = Query(None),
    source: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    q = select(Report).order_by(Report.created_at.desc())
    count_q = select(func.count(Report.id))

    if status:
        if status not in REPORT_STATUSES:
            raise HTTPException(status_code=400, detail="Invalid status")
        q = q.where(Report.status == status)
        count_q = count_q.where(Report.status == status)
    if target_type:
        q = q.where(Report.target_type == target_type)
        count_q = count_q.where(Report.target_type == target_type)
    if source:
        q = q.where(Report.source == source)
        count_q = count_q.where(Report.source == source)

    total = (await db.execute(count_q)).scalar() or 0
    result = await db.execute(q.offset((page - 1) * per_page).limit(per_page))
    reports = list(result.scalars().all())

    # Resolve reporter / target_author names in two batched queries.
    user_ids: set[UUID] = set()
    for r in reports:
        if r.reporter_id:
            user_ids.add(r.reporter_id)
        if r.target_author_id:
            user_ids.add(r.target_author_id)
    name_by_id: dict[UUID, str | None] = {}
    if user_ids:
        users_q = await db.execute(
            select(User.id, User.name).where(User.id.in_(user_ids))
        )
        for uid, name in users_q.all():
            name_by_id[uid] = name

    return {
        "reports": [
            {
                "id": str(r.id),
                "reporter_id": str(r.reporter_id) if r.reporter_id else None,
                "reporter_name": name_by_id.get(r.reporter_id),
                "target_type": r.target_type,
                "target_id": r.target_id,
                "target_author_id": (
                    str(r.target_author_id) if r.target_author_id else None
                ),
                "target_author_name": name_by_id.get(r.target_author_id),
                "reason": r.reason,
                "note": r.note,
                "snapshot": r.snapshot,
                "ai_meta": r.ai_meta,
                "source": r.source,
                "status": r.status,
                "resolver_id": (
                    str(r.resolver_id) if r.resolver_id else None
                ),
                "resolved_at": (
                    r.resolved_at.isoformat() if r.resolved_at else None
                ),
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
            for r in reports
        ],
        "total": total,
        "page": page,
        "per_page": per_page,
        "total_pages": (total + per_page - 1) // per_page if total else 0,
    }


@router.get("/api/admin/reports/stats")
async def report_stats(
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    rows = (
        await db.execute(
            select(Report.status, func.count(Report.id))
            .group_by(Report.status)
        )
    ).all()
    by_status = {s: 0 for s in REPORT_STATUSES}
    for status, count in rows:
        by_status[status] = int(count)
    return by_status


@router.patch("/api/admin/reports/{report_id}")
async def update_report(
    report_id: str,
    payload: ReportUpdate,
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    try:
        rid = UUID(report_id)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid report id")

    result = await db.execute(select(Report).where(Report.id == rid))
    report = result.scalar_one_or_none()
    if report is None:
        raise HTTPException(status_code=404, detail="Report not found")

    report.status = payload.status
    if payload.status in ("actioned", "dismissed"):
        report.resolved_at = datetime.now(timezone.utc)
    else:
        report.resolved_at = None
    await db.commit()
    return {"status": "ok"}


# ── Helpers ────────────────────────────────────────────────────────────────

async def _resolve_target(
    db: AsyncSession,
    reporter: User,
    target_type: str,
    target_id: str,
) -> tuple[str | None, UUID | None]:
    """Validate the target exists and return (snapshot, author_id).

    For chat messages we additionally require the reporter to be a
    participant in the conversation — you can't report a message you
    can't see.
    """
    try:
        tid = UUID(target_id)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid target id")

    if target_type == "story":
        row = await db.execute(select(FeedItem).where(FeedItem.id == tid))
        item = row.scalar_one_or_none()
        if item is None:
            raise HTTPException(status_code=404, detail="Story not found")
        snippet = (item.title or "") + (
            f" — {item.description}" if item.description else ""
        )
        return snippet[:1000].strip() or None, item.author_id

    if target_type == "comment":
        row = await db.execute(select(Comment).where(Comment.id == tid))
        comment = row.scalar_one_or_none()
        if comment is None:
            raise HTTPException(status_code=404, detail="Comment not found")
        return (comment.text or "")[:1000] or None, comment.author_id

    if target_type == "user":
        row = await db.execute(select(User).where(User.id == tid))
        target = row.scalar_one_or_none()
        if target is None:
            raise HTTPException(status_code=404, detail="User not found")
        if target.id == reporter.id:
            raise HTTPException(
                status_code=400, detail="Cannot report yourself"
            )
        return target.name, target.id

    if target_type == "chat_message":
        row = await db.execute(
            select(ChatMessage, Conversation)
            .join(Conversation, ChatMessage.conversation_id == Conversation.id)
            .where(ChatMessage.id == tid)
        )
        result = row.first()
        if result is None:
            raise HTTPException(status_code=404, detail="Message not found")
        msg, convo = result
        if reporter.id not in (convo.user_a_id, convo.user_b_id):
            raise HTTPException(status_code=403, detail="Not a participant")
        return (msg.body or "")[:1000] or None, msg.sender_id

    raise HTTPException(status_code=400, detail="Unknown target_type")
