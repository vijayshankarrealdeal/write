import time

from fastapi import APIRouter, Depends, HTTPException, UploadFile

from app.auth.deps import get_current_user
from app.models.user import User
from app.storage import upload_file

router = APIRouter(prefix="/api/upload", tags=["upload"])

MAX_SIZE = 5 * 1024 * 1024  # 5MB


@router.post("/profile")
async def upload_profile_photo(
    file: UploadFile,
    user: User = Depends(get_current_user),
):
    data = await file.read()
    if len(data) > MAX_SIZE:
        raise HTTPException(status_code=413, detail="File too large (max 5MB)")

    path = f"users/{user.id}/profile/avatar.jpg"
    url = await upload_file(path, data, content_type=file.content_type or "image/jpeg")
    return {"url": url}


@router.post("/cover/{book_id}")
async def upload_cover_image(
    book_id: str,
    file: UploadFile,
    user: User = Depends(get_current_user),
):
    data = await file.read()
    if len(data) > MAX_SIZE:
        raise HTTPException(status_code=413, detail="File too large (max 5MB)")

    path = f"users/{user.id}/covers/{book_id}.jpg"
    url = await upload_file(path, data, content_type=file.content_type or "image/jpeg")
    return {"url": url}


@router.post("/editor")
async def upload_editor_image(
    file: UploadFile,
    user: User = Depends(get_current_user),
):
    data = await file.read()
    if len(data) > MAX_SIZE:
        raise HTTPException(status_code=413, detail="File too large (max 5MB)")

    timestamp = int(time.time() * 1000)
    path = f"users/{user.id}/editor/{timestamp}.jpg"
    url = await upload_file(path, data, content_type=file.content_type or "image/jpeg")
    return {"url": url}
