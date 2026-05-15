"""Exponential backoff for transient API errors (429, 5xx, timeouts)."""
from __future__ import annotations

import asyncio
from typing import Awaitable, Callable, TypeVar

T = TypeVar("T")


_TRANSIENT_HINTS = (
    "429", "500", "502", "503", "504",
    "timeout", "connection", "rate limit", "temporarily",
)


async def with_retries(
    fn: Callable[[], Awaitable[T]],
    *,
    max_attempts: int = 4,
    base_delay: float = 1.0,
    label: str = "",
) -> T:
    last_exc: Exception | None = None
    for attempt in range(1, max_attempts + 1):
        try:
            return await fn()
        except Exception as exc:
            last_exc = exc
            msg = str(exc).lower()
            transient = any(hint in msg for hint in _TRANSIENT_HINTS)
            if not transient or attempt == max_attempts:
                raise
            delay = base_delay * (2 ** (attempt - 1))
            print(
                f"[retry {label}] attempt {attempt}/{max_attempts} "
                f"failed transiently ({exc}); sleeping {delay:.1f}s"
            )
            await asyncio.sleep(delay)
    if last_exc:
        raise last_exc
    raise RuntimeError("with_retries exhausted without exception")
