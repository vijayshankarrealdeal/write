"""Public endpoint for client apps to report crashes/errors."""

from fastapi import APIRouter, Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models.analytics import CrashReport

router = APIRouter(prefix="/api/crashes", tags=["crashes"])


@router.post("")
async def report_crash(
    payload: dict,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """Accept a crash report from any client app (Flutter, web, etc.).

    Required fields: error_type, error_message
    Optional: stack_trace, page, device, platform, app_version, user_id
    """
    if "error_type" not in payload or "error_message" not in payload:
        return {"status": "error", "detail": "error_type and error_message required"}

    crash = CrashReport(
        user_id=payload.get("user_id"),
        error_type=str(payload["error_type"])[:200],
        error_message=str(payload["error_message"])[:10000],
        stack_trace=payload.get("stack_trace"),
        page=payload.get("page"),
        device=payload.get("device") or request.headers.get("user-agent", "")[:200],
        platform=payload.get("platform"),
        app_version=payload.get("app_version"),
    )
    db.add(crash)
    await db.commit()
    return {"status": "ok", "id": str(crash.id)}
