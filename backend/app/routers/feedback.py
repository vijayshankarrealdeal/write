"""User feedback about the app + admin review queue.

Two surfaces, mirrors `app.routers.reports`:
- `/api/feedback`: authenticated users submit feedback (bug, feature,
  praise, other).
- `/api/admin/feedback`: admin-only listing + status updates, using the
  same query-param token auth as the rest of the admin surface.
"""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.feedback import FEEDBACK_CATEGORIES, FEEDBACK_STATUSES, Feedback
from app.models.user import User
from app.routers.admin import _verify_admin
from app.schemas.feedback import FeedbackCreate, FeedbackUpdate

router = APIRouter(tags=["feedback"])


# ── User-facing: submit feedback ────────────────────────────────────────────

@router.post("/api/feedback", status_code=201)
async def create_feedback(
    payload: FeedbackCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    fb = Feedback(
        user_id=user.id,
        category=payload.category,
        message=payload.message.strip(),
        platform=payload.platform,
        app_version=payload.app_version,
        status="new",
    )
    db.add(fb)
    await db.commit()
    await db.refresh(fb)
    return {"status": "ok", "id": str(fb.id)}


# ── Admin-facing: list + update ────────────────────────────────────────────

@router.get("/api/admin/feedback")
async def list_feedback(
    page: int = Query(1, ge=1),
    per_page: int = Query(25, ge=1, le=100),
    status: str | None = Query(None),
    category: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    q = select(Feedback).order_by(Feedback.created_at.desc())
    count_q = select(func.count(Feedback.id))

    if status:
        if status not in FEEDBACK_STATUSES:
            raise HTTPException(status_code=400, detail="Invalid status")
        q = q.where(Feedback.status == status)
        count_q = count_q.where(Feedback.status == status)
    if category:
        if category not in FEEDBACK_CATEGORIES:
            raise HTTPException(status_code=400, detail="Invalid category")
        q = q.where(Feedback.category == category)
        count_q = count_q.where(Feedback.category == category)

    total = (await db.execute(count_q)).scalar() or 0
    result = await db.execute(q.offset((page - 1) * per_page).limit(per_page))
    items = list(result.scalars().all())

    user_ids = {fb.user_id for fb in items if fb.user_id}
    user_by_id: dict[UUID, tuple[str | None, str | None]] = {}
    if user_ids:
        rows = await db.execute(
            select(User.id, User.name, User.email).where(User.id.in_(user_ids))
        )
        for uid, name, email in rows.all():
            user_by_id[uid] = (name, email)

    return {
        "feedback": [
            {
                "id": str(fb.id),
                "user_id": str(fb.user_id) if fb.user_id else None,
                "user_name": user_by_id.get(fb.user_id, (None, None))[0]
                if fb.user_id else None,
                "user_email": user_by_id.get(fb.user_id, (None, None))[1]
                if fb.user_id else None,
                "category": fb.category,
                "message": fb.message,
                "platform": fb.platform,
                "app_version": fb.app_version,
                "status": fb.status,
                "resolver_id": str(fb.resolver_id) if fb.resolver_id else None,
                "resolved_at": (
                    fb.resolved_at.isoformat() if fb.resolved_at else None
                ),
                "created_at": fb.created_at.isoformat() if fb.created_at else None,
            }
            for fb in items
        ],
        "total": total,
        "page": page,
        "per_page": per_page,
        "total_pages": (total + per_page - 1) // per_page if total else 0,
    }


@router.get("/api/admin/feedback/stats")
async def feedback_stats(
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    rows = (
        await db.execute(
            select(Feedback.status, func.count(Feedback.id))
            .group_by(Feedback.status)
        )
    ).all()
    by_status = {s: 0 for s in FEEDBACK_STATUSES}
    for status, count in rows:
        by_status[status] = int(count)
    return by_status


@router.patch("/api/admin/feedback/{feedback_id}")
async def update_feedback(
    feedback_id: str,
    payload: FeedbackUpdate,
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_admin),
):
    try:
        fid = UUID(feedback_id)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid feedback id")

    result = await db.execute(select(Feedback).where(Feedback.id == fid))
    fb = result.scalar_one_or_none()
    if fb is None:
        raise HTTPException(status_code=404, detail="Feedback not found")

    fb.status = payload.status
    if payload.status == "resolved":
        fb.resolved_at = datetime.now(timezone.utc)
    else:
        fb.resolved_at = None
    await db.commit()
    return {"status": "ok"}
