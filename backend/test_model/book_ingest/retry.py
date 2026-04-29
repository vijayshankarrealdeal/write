"""Exponential-backoff retry decorator for transient failures.

Targets the common failure modes during a 3000-page run:
  - openai.APIConnectionError      (DNS hiccup, TLS reset, Wi-Fi flap)
  - openai.APITimeoutError         (slow network, model overload)
  - openai.RateLimitError          (Azure TPM cap)
  - openai.InternalServerError     (Azure 5xx)
  - asyncio.TimeoutError, ConnectionError (lower-level network)

Permanent errors (4xx other than 429) bubble immediately so the orchestrator
can record the failure for that one item and move on without burning
backoff time on something that will never succeed.
"""

from __future__ import annotations

import asyncio
import random
from typing import Awaitable, Callable, TypeVar

T = TypeVar("T")


# We want to import these lazily — `openai` / `pydantic_ai` may not be
# installed in every context where this module is imported (e.g.
# local-only testing). Resolve them once at module load and treat any
# unresolvable name as a no-match.
def _openai_transient_classes() -> tuple[type[BaseException], ...]:
    classes: list[type[BaseException]] = []
    try:
        import openai  # type: ignore
        for name in (
            "APIConnectionError",
            "APITimeoutError",
            "RateLimitError",
            "InternalServerError",
            "APIStatusError",  # parent of 5xx; we filter status below
        ):
            cls = getattr(openai, name, None)
            if isinstance(cls, type) and issubclass(cls, BaseException):
                classes.append(cls)
    except ImportError:
        pass

    # pydantic_ai wraps the underlying OpenAI SDK errors in its own
    # `ModelHTTPError` for some failure paths. Treat those as transient
    # too — most of the time they're a 429 / 5xx that's worth retrying.
    try:
        import pydantic_ai  # type: ignore
        for mod_path in ("pydantic_ai.exceptions", "pydantic_ai"):
            try:
                mod = __import__(mod_path, fromlist=["ModelHTTPError"])
            except ImportError:
                continue
            for name in ("ModelHTTPError", "UnexpectedModelBehavior"):
                cls = getattr(mod, name, None)
                if isinstance(cls, type) and issubclass(cls, BaseException):
                    classes.append(cls)
    except ImportError:
        pass

    return tuple(classes)


_OPENAI_TRANSIENT = _openai_transient_classes()


_TRANSIENT_KEYWORDS = (
    "rate limit",
    "rate_limit",
    "429",
    "timeout",
    "timed out",
    "connection error",
    "connection reset",
    "connection aborted",
    "temporarily unavailable",
    "service unavailable",
    "bad gateway",
    "gateway timeout",
    "internal server error",
    "model_http_error",   # pydantic_ai wraps upstream HTTP errors here
    "modelhttperror",
    "503",
    "502",
    "504",
    "500",
)


def _is_transient(exc: BaseException) -> bool:
    if isinstance(exc, asyncio.TimeoutError):
        return True
    if isinstance(exc, ConnectionError):
        return True
    if _OPENAI_TRANSIENT and isinstance(exc, _OPENAI_TRANSIENT):
        # APIStatusError covers everything from 4xx to 5xx — only count
        # 5xx (and 429) as transient.
        status = getattr(exc, "status_code", None)
        if status is not None:
            return status >= 500 or status == 429
        return True
    msg = str(exc).lower()
    return any(k in msg for k in _TRANSIENT_KEYWORDS)


async def with_retries(
    fn: Callable[[], Awaitable[T]],
    *,
    attempts: int = 6,
    base_delay: float = 1.5,
    max_delay: float = 60.0,
    label: str = "call",
) -> T:
    """Call `fn()` with exponential backoff on transient errors.

    Sleep schedule: base * 2^n + jitter, capped at `max_delay`. Re-raises
    after `attempts` failures; raises immediately on a permanent (non-
    transient) error so we don't waste backoff time on it.
    """
    last_exc: BaseException | None = None
    for n in range(attempts):
        try:
            return await fn()
        except Exception as exc:  # noqa: BLE001 — re-raised below if not transient
            last_exc = exc
            if not _is_transient(exc) or n == attempts - 1:
                raise
            delay = min(max_delay, base_delay * (2 ** n)) + random.uniform(0, 0.5)
            print(f"[retry] {label} attempt {n + 1}/{attempts} failed ({type(exc).__name__}: {exc}); "
                  f"sleeping {delay:.1f}s")
            await asyncio.sleep(delay)
    assert last_exc is not None
    raise last_exc
