from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field


# Allowed message kinds. Mirrored on the Flutter side so the discriminator
# is stable across releases. Add new kinds here AND on the client.
MESSAGE_KINDS = {"text", "image", "book", "excerpt", "section"}


class MessageCreate(BaseModel):
    kind: str = "text"
    body: str | None = None
    attachment: dict | None = None


class MessageResponse(BaseModel):
    id: UUID
    conversation_id: UUID
    sender_id: UUID
    kind: str
    body: str | None
    attachment: dict | None
    created_at: datetime

    model_config = {"from_attributes": True}


class ConversationStartRequest(BaseModel):
    other_user_id: UUID


class ConversationParticipant(BaseModel):
    id: UUID
    name: str | None
    photo_url: str | None
    photo_meta: dict | None = None


class ConversationResponse(BaseModel):
    id: UUID
    other_user: ConversationParticipant
    last_message_at: datetime | None
    last_message_preview: str | None
    unread_count: int = Field(default=0)
    created_at: datetime
