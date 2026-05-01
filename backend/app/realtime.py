"""Pub/sub hub for SSE channels.

Each subscriber holds an asyncio.Queue of pending messages. ``broadcast``
delivers a payload to every subscriber's queue; the SSE endpoint drains
its queue and writes ``data:`` frames to the client.

Three channel kinds:
- ``user:{user_id}`` — private per-user channel for notifications.
- ``feed:{feed_item_id}`` — comment events for a specific post.
- ``writing:{writing_id}`` — live-edit events for a draft (shared
  between the author's devices).

Two backends:
- **In-memory** (default, ``REDIS_URL`` empty) — single-process only;
  ``broadcast`` fans out directly to local queues.
- **Redis pub/sub** (``REDIS_URL`` set) — every ``broadcast`` becomes a
  ``PUBLISH`` on the matching Redis channel, and a background reader on
  each worker ``PSUBSCRIBE``s to the channel namespaces and dispatches
  incoming messages to local queues. Same-process subscribers receive
  via the Redis round-trip too, which keeps the code path uniform and
  avoids double-delivery.
"""

from __future__ import annotations

import asyncio
import json
from collections import defaultdict
from typing import Any, AsyncIterator
from uuid import UUID

from app.config import settings
from app.logger import get_logger

log = get_logger("app.realtime")

# Patterns the Redis reader subscribes to. Add new channel kinds here so
# they get fanned out across workers.
_REDIS_PATTERNS = ("user:*", "feed:*", "writing:*")


class _Hub:
    # Bound the per-subscriber queue so a slow client can't grow memory
    # without limit. Drop oldest on overflow — notifications/comments are
    # eventually re-fetchable via REST, so dropping is recoverable.
    _MAX_QUEUE = 100

    def __init__(self) -> None:
        self._channels: dict[str, set[asyncio.Queue]] = defaultdict(set)
        self._lock = asyncio.Lock()
        self._redis: Any | None = None
        self._reader_task: asyncio.Task | None = None

    async def start(self) -> None:
        """Connect to Redis (if configured) and start the pubsub reader.

        No-op when ``REDIS_URL`` is empty — the hub stays in-memory.
        Failures here are fatal: a misconfigured Redis URL on a
        multi-worker deployment would silently break SSE fanout, so we
        let the lifespan crash instead.
        """
        if not settings.redis_url:
            return
        # Imported lazily so single-worker deployments don't need the
        # `redis` package installed at import time (it still is, via
        # requirements.txt — but this keeps the dev path tolerant of
        # local environments without Redis).
        from redis import asyncio as redis_asyncio

        self._redis = redis_asyncio.from_url(
            settings.redis_url,
            decode_responses=True,
            health_check_interval=30,
        )
        # `ping` surfaces auth/host errors at startup rather than on the
        # first publish. Lifespan startup is the right place for this to
        # blow up.
        await self._redis.ping()
        self._reader_task = asyncio.create_task(
            self._redis_reader_loop(), name="realtime-redis-reader"
        )
        log.info("realtime hub: Redis backend connected (%s)", settings.redis_url)

    async def stop(self) -> None:
        if self._reader_task is not None:
            self._reader_task.cancel()
            try:
                await self._reader_task
            except (asyncio.CancelledError, Exception):
                pass
            self._reader_task = None
        if self._redis is not None:
            try:
                await self._redis.close()
            except Exception:
                pass
            self._redis = None

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
        if self._redis is not None:
            # Cross-worker path: publish to Redis. The reader on each
            # worker (including this one) will dispatch the message back
            # into local queues via `_dispatch_local`.
            try:
                body = json.dumps(payload, default=_default_json)
                await self._redis.publish(channel, body)
            except Exception:
                # Don't let a transient Redis blip break the request that
                # triggered the broadcast. The mutation already
                # committed; the worst case is a missed live update,
                # which clients recover from on next REST refresh.
                log.exception("redis publish failed on channel=%s", channel)
            return
        await self._dispatch_local(channel, payload)

    async def _dispatch_local(self, channel: str, payload: dict[str, Any]) -> None:
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

    async def _redis_reader_loop(self) -> None:
        """Subscribe to the channel patterns and dispatch to local queues.

        Runs forever (until cancelled on shutdown) with reconnect
        backoff: a Redis disconnect should not require a worker restart.
        """
        backoff = 1.0
        while True:
            pubsub = None
            try:
                pubsub = self._redis.pubsub()
                await pubsub.psubscribe(*_REDIS_PATTERNS)
                backoff = 1.0  # reset after a successful subscribe
                async for message in pubsub.listen():
                    if message is None:
                        continue
                    if message.get("type") not in ("pmessage", "message"):
                        continue
                    channel = message.get("channel")
                    data = message.get("data")
                    if not isinstance(channel, str) or not isinstance(data, str):
                        continue
                    try:
                        payload = json.loads(data)
                    except json.JSONDecodeError:
                        log.warning("realtime: dropping malformed payload on %s", channel)
                        continue
                    if not isinstance(payload, dict):
                        continue
                    await self._dispatch_local(channel, payload)
            except asyncio.CancelledError:
                if pubsub is not None:
                    try:
                        await pubsub.punsubscribe(*_REDIS_PATTERNS)
                        await pubsub.close()
                    except Exception:
                        pass
                raise
            except Exception:
                log.exception("realtime: redis reader crashed, reconnecting in %.1fs", backoff)
                if pubsub is not None:
                    try:
                        await pubsub.close()
                    except Exception:
                        pass
                await asyncio.sleep(backoff)
                # Cap backoff at 30s — Redis outages longer than that
                # are operator-visible anyway.
                backoff = min(backoff * 2, 30.0)

    async def send_to_user(self, user_id: UUID, payload: dict[str, Any]) -> None:
        await self.broadcast(f"user:{user_id}", payload)

    async def broadcast_feed_item(
        self, feed_item_id: UUID, payload: dict[str, Any]
    ) -> None:
        await self.broadcast(f"feed:{feed_item_id}", payload)

    async def broadcast_writing(
        self, writing_id: UUID, payload: dict[str, Any]
    ) -> None:
        await self.broadcast(f"writing:{writing_id}", payload)


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
