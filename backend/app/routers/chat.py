"""One-on-one chat REST API.

Pairs with the realtime hub (`user:{id}` channel) — a new message fans
out to both participants over the existing SSE pipe so clients update
without polling. The REST surface covers conversation discovery, history,
and send.
"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.deps import get_current_user
from app.database import get_db
from app.models.chat import ChatMessage, Conversation
from app.models.user import User
from app.realtime import hub
from app.schemas.chat import (
    MESSAGE_KINDS,
    ConversationParticipant,
    ConversationResponse,
    ConversationStartRequest,
    MessageCreate,
    MessageResponse,
)

router = APIRouter(prefix="/api/chats", tags=["chat"])


def _canonical_pair(a: UUID, b: UUID) -> tuple[UUID, UUID]:
    """Sort the user pair so (user_a_id, user_b_id) is deterministic."""
    return (a, b) if str(a) < str(b) else (b, a)


def _serialize_message(msg: ChatMessage) -> dict:
    return {
        "id": str(msg.id),
        "conversation_id": str(msg.conversation_id),
        "sender_id": str(msg.sender_id),
        "kind": msg.kind,
        "body": msg.body,
        "attachment": msg.attachment,
        "created_at": msg.created_at.isoformat() if msg.created_at else None,
    }


async def _load_conversation(
    db: AsyncSession, conversation_id: UUID, user_id: UUID
) -> Conversation:
    result = await db.execute(
        select(Conversation).where(
            Conversation.id == conversation_id,
            or_(
                Conversation.user_a_id == user_id,
                Conversation.user_b_id == user_id,
            ),
        )
    )
    convo = result.scalar_one_or_none()
    if convo is None:
        raise HTTPException(status_code=404, detail="Conversation not found")
    return convo


@router.get("/", response_model=list[ConversationResponse])
async def list_conversations(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # Conversations the user participates in, ordered by recency.
    rows = await db.execute(
        select(Conversation)
        .where(
            or_(
                Conversation.user_a_id == user.id,
                Conversation.user_b_id == user.id,
            )
        )
        .order_by(
            Conversation.last_message_at.desc().nulls_last(),
            Conversation.created_at.desc(),
        )
    )
    conversations = list(rows.scalars().all())
    if not conversations:
        return []

    # Resolve the "other user" for each conversation in one query.
    other_ids: list[UUID] = []
    for c in conversations:
        other_ids.append(c.user_b_id if c.user_a_id == user.id else c.user_a_id)
    users_q = await db.execute(select(User).where(User.id.in_(other_ids)))
    users_by_id = {u.id: u for u in users_q.scalars().all()}

    # Per-conversation unread count: messages not sent by me and not read.
    unread_q = await db.execute(
        select(
            ChatMessage.conversation_id,
            func.count(ChatMessage.id),
        )
        .where(
            ChatMessage.conversation_id.in_([c.id for c in conversations]),
            ChatMessage.sender_id != user.id,
            ChatMessage.read_by_recipient.is_(False),
        )
        .group_by(ChatMessage.conversation_id)
    )
    unread_by_conv = {row[0]: int(row[1]) for row in unread_q.all()}

    out: list[ConversationResponse] = []
    for c in conversations:
        other_id = c.user_b_id if c.user_a_id == user.id else c.user_a_id
        other = users_by_id.get(other_id)
        if other is None:
            continue
        out.append(
            ConversationResponse(
                id=c.id,
                other_user=ConversationParticipant(
                    id=other.id,
                    name=other.name,
                    photo_url=other.photo_url,
                    photo_meta=other.photo_meta,
                ),
                last_message_at=c.last_message_at,
                last_message_preview=c.last_message_preview,
                unread_count=unread_by_conv.get(c.id, 0),
                created_at=c.created_at,
            )
        )
    return out


@router.post(
    "/start", response_model=ConversationResponse, status_code=200
)
async def start_conversation(
    data: ConversationStartRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get-or-create a conversation with `other_user_id`."""
    if data.other_user_id == user.id:
        raise HTTPException(
            status_code=400, detail="Cannot start a chat with yourself"
        )

    # Verify the other user exists.
    other_q = await db.execute(select(User).where(User.id == data.other_user_id))
    other = other_q.scalar_one_or_none()
    if other is None:
        raise HTTPException(status_code=404, detail="User not found")

    a_id, b_id = _canonical_pair(user.id, data.other_user_id)
    existing_q = await db.execute(
        select(Conversation).where(
            Conversation.user_a_id == a_id, Conversation.user_b_id == b_id
        )
    )
    convo = existing_q.scalar_one_or_none()
    if convo is None:
        convo = Conversation(user_a_id=a_id, user_b_id=b_id)
        db.add(convo)
        await db.commit()
        await db.refresh(convo)

    return ConversationResponse(
        id=convo.id,
        other_user=ConversationParticipant(
            id=other.id,
            name=other.name,
            photo_url=other.photo_url,
            photo_meta=other.photo_meta,
        ),
        last_message_at=convo.last_message_at,
        last_message_preview=convo.last_message_preview,
        unread_count=0,
        created_at=convo.created_at,
    )


@router.get(
    "/{conversation_id}/messages", response_model=list[MessageResponse]
)
async def list_messages(
    conversation_id: UUID,
    limit: int = Query(50, le=200),
    before: str | None = None,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await _load_conversation(db, conversation_id, user.id)
    query = select(ChatMessage).where(
        ChatMessage.conversation_id == conversation_id
    )
    if before:
        try:
            cursor_id = UUID(before)
            cursor_q = await db.execute(
                select(ChatMessage).where(ChatMessage.id == cursor_id)
            )
            cursor_msg = cursor_q.scalar_one_or_none()
            if cursor_msg is not None:
                query = query.where(
                    ChatMessage.created_at < cursor_msg.created_at
                )
        except ValueError:
            pass
    query = query.order_by(ChatMessage.created_at.desc()).limit(limit)
    result = await db.execute(query)
    msgs = list(result.scalars().all())
    # Return oldest-first so the client can append to the bottom.
    msgs.reverse()
    return msgs


@router.post(
    "/{conversation_id}/messages",
    response_model=MessageResponse,
    status_code=201,
)
async def send_message(
    conversation_id: UUID,
    data: MessageCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    convo = await _load_conversation(db, conversation_id, user.id)
    if data.kind not in MESSAGE_KINDS:
        raise HTTPException(
            status_code=400,
            detail=f"kind must be one of {sorted(MESSAGE_KINDS)}",
        )
    body = (data.body or "").strip() or None
    if data.kind == "text" and not body:
        raise HTTPException(status_code=400, detail="body is required for text")
    if data.kind != "text" and data.attachment is None and not body:
        raise HTTPException(
            status_code=400,
            detail="attachment or body is required for non-text messages",
        )

    msg = ChatMessage(
        conversation_id=conversation_id,
        sender_id=user.id,
        kind=data.kind,
        body=body,
        attachment=data.attachment,
    )
    db.add(msg)

    preview = _preview_for(data.kind, body, data.attachment)
    convo.last_message_at = func.now()
    convo.last_message_preview = preview

    await db.flush()
    await db.refresh(msg)
    await db.commit()

    # Push to both participants — the sender sees the message echoed on
    # other devices, the recipient gets the live update.
    payload = {"type": "chat.message", "message": _serialize_message(msg)}
    other_id = convo.user_b_id if convo.user_a_id == user.id else convo.user_a_id
    await hub.send_to_user(user.id, payload)
    await hub.send_to_user(other_id, payload)

    return msg


@router.post("/{conversation_id}/read", status_code=204)
async def mark_read(
    conversation_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await _load_conversation(db, conversation_id, user.id)
    await db.execute(
        update(ChatMessage)
        .where(
            ChatMessage.conversation_id == conversation_id,
            ChatMessage.sender_id != user.id,
            ChatMessage.read_by_recipient.is_(False),
        )
        .values(read_by_recipient=True)
    )
    await db.commit()


@router.get("/unread-count")
async def unread_total(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # Count unread messages addressed to me across all my conversations.
    result = await db.execute(
        select(func.count(ChatMessage.id))
        .join(Conversation, ChatMessage.conversation_id == Conversation.id)
        .where(
            or_(
                Conversation.user_a_id == user.id,
                Conversation.user_b_id == user.id,
            ),
            ChatMessage.sender_id != user.id,
            ChatMessage.read_by_recipient.is_(False),
        )
    )
    return {"unread": int(result.scalar() or 0)}


def _preview_for(kind: str, body: str | None, attachment: dict | None) -> str | None:
    if kind == "text":
        return (body or "")[:240] or None
    if kind == "image":
        return "📷 Photo"
    if kind == "book":
        title = (attachment or {}).get("title")
        return f"📖 {title}" if title else "📖 Shared a book"
    if kind == "excerpt":
        title = (attachment or {}).get("title")
        return f"❝ {title}" if title else "❝ Shared lines"
    if kind == "section":
        title = (attachment or {}).get("title")
        return f"📄 {title}" if title else "📄 Shared a section"
    return body
