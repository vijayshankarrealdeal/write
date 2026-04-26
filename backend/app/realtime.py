"""In-process pub/sub hub for SSE channels.

Each subscriber holds an asyncio.Queue of pending messages. ``broadcast``
puts a payload onto every subscriber's queue; the SSE endpoint drains
its queue and writes ``data:`` frames to the client.

Two channel kinds:
- ``user:{user_id}`` — private per-user channel for notifications.
- ``feed:{feed_item_id}`` — comment events for a specific post.

Single-process only. Swap the in-memory queues for Redis pub/sub if the
API ever runs multiple workers — only ``broadcast``, ``send_to_user``,
and ``broadcast_feed_item`` need to change.
"""

from __future__ import annotations

import asyncio
import json
from collections import defaultdict
from typing import Any, AsyncIterator
from uuid import UUID

from app.logger import get_logger

log = get_logger("app.realtime")


class _Hub:
    # Bound the per-subscriber queue so a slow client can't grow memory
    # without limit. Drop oldest on overflow — notifications/comments are
    # eventually re-fetchable via REST, so dropping is recoverable.
    _MAX_QUEUE = 100

    def __init__(self) -> None:
        self._channels: dict[str, set[asyncio.Queue]] = defaultdict(set)
        self._lock = asyncio.Lock()

    async def subscribe(self, channel: str) -> asyncio.Queue:
        queue: asyncio.Queue = asyncio.Queue(maxsize=self._MAX_QUEUE)
        async with self._lock:
            self._channels[channel].add(queue)
        return queue

    async def unsubscribe(self, channel: str, queue: asyncio.Queue) -> None:
        async with self._lock:
            members = self._channels.get(channel)
            if members is None:
                return
            members.discard(queue)
            if not members:
                self._channels.pop(channel, None)

    async def broadcast(self, channel: str, payload: dict[str, Any]) -> None:
        async with self._lock:
            members = list(self._channels.get(channel, ()))
        if not members:
            return
        for queue in members:
            try:
                queue.put_nowait(payload)
            except asyncio.QueueFull:
                # Drop oldest to make room — keep the stream live.
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
                try:
                    queue.put_nowait(payload)
                except asyncio.QueueFull:
                    pass

    async def send_to_user(self, user_id: UUID, payload: dict[str, Any]) -> None:
        await self.broadcast(f"user:{user_id}", payload)

    async def broadcast_feed_item(
        self, feed_item_id: UUID, payload: dict[str, Any]
    ) -> None:
        await self.broadcast(f"feed:{feed_item_id}", payload)


def _default_json(value: Any) -> Any:
    if isinstance(value, UUID):
        return str(value)
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return str(value)


def encode_sse_event(payload: dict[str, Any], *, event_id: str | None = None) -> bytes:
    """Format a payload as an SSE frame.

    SSE frame grammar (whitwspace-significant):
        id: <event_id>\n
        data: <one-line JSON>\n\n
    """
    lines: list[str] = []
    if event_id is not None:
        lines.append(f"id: {event_id}")
    body = json.dumps(payload, default=_default_json)
    lines.append(f"data: {body}")
    lines.append("")  # trailing blank line terminates the event
    lines.append("")
    return "\n".join(lines).encode("utf-8")


async def event_stream(channel: str, *, heartbeat: float = 20.0) -> AsyncIterator[bytes]:
    """Async generator that yields SSE frames for [channel].

    Sends a comment-only heartbeat (`: ping\n\n`) every ``heartbeat``
    seconds so idle proxies don't time the connection out and the client
    notices a half-open socket quickly.
    """
    queue = await hub.subscribe(channel)
    try:
        # Initial frame — confirms the connection is live before any real
        # event arrives. Useful so the client can flip its "online" state.
        yield b": connected\n\n"
        while True:
            try:
                payload = await asyncio.wait_for(queue.get(), timeout=heartbeat)
            except asyncio.TimeoutError:
                yield b": heartbeat\n\n"
                continue
            yield encode_sse_event(payload, event_id=str(payload.get("id", "")))
    except asyncio.CancelledError:
        # Client disconnected — let the cancellation propagate so FastAPI
        # cleans up, and ensure we drop our subscription in the finally.
        raise
    finally:
        await hub.unsubscribe(channel, queue)


hub = _Hub()
