"""IP → country-code resolution.

Two-tier lookup, designed to be swapped without changing callers:

1. **Caddy-set header** (`X-Country-Code`) — preferred. If Caddy is
   built with the `maxmind_geolocation` plugin it injects the header
   on every reverse-proxy request and the lookup is a constant-time
   dict read. No network call from the backend; no third-party
   dependency at request time. Operator-side cost: rebuild Caddy with
   the plugin + mount a MaxMind GeoLite2 country DB (refreshed
   monthly). The commented stanza in the project's `Caddyfile` shows
   the exact config.
2. **`ip-api.com` fallback** — if no header is present, the backend
   makes a single outbound HTTP call to `ip-api.com/json/{ip}`. Free
   tier, no API key, ~50ms typical. Cached in-process keyed on the
   IP so repeated unauthenticated callers from the same NAT egress
   don't fan out N upstream calls. Hard 1.5s timeout — a stalled
   ip-api request must not block auth.

Both paths return an uppercased two-letter ISO 3166-1 alpha-2 code
(`"IN"`, `"US"`, `"GB"`, ...) or `None` on failure. Callers persist
to `users.country_code` on first resolution and never look up again
for that user.
"""
from __future__ import annotations

import asyncio
import logging
import re
from typing import Final

import httpx
from fastapi import Request


log = logging.getLogger("app.geo")

# Two-letter country codes only. Anything else returned by an upstream
# (e.g. a `null` from ip-api when the IP is bogon, or a long-form
# string from a misconfigured Caddy header) is discarded so we never
# write garbage into `users.country_code`.
_CC_RE: Final = re.compile(r"^[A-Z]{2}$")

# Header name Caddy is expected to set when the `maxmind_geolocation`
# plugin is installed. Matches the Caddyfile snippet.
_HEADER_NAME: Final = "X-Country-Code"

# Hard upper bound on how long we'll wait for ip-api. The auth deps
# kicks resolution off as a background task anyway, but the bound is
# also a guard against the task piling up if upstream is degraded.
_IP_API_TIMEOUT_SECONDS: Final = 1.5

# Small in-process cache. The same IP authenticating multiple users
# (shared NAT, office network, mobile carrier CGNAT) shouldn't fan out
# to ip-api once per user — cache by IP and serve hits from RAM. Cap
# is small because per-process memory cost is what we care about;
# the persistent answer lives on `users.country_code` anyway.
_CACHE: dict[str, str | None] = {}
_CACHE_MAX_ENTRIES: Final = 1024


def _validate(code: str | None) -> str | None:
    """Return the code uppercased if it matches /^[A-Z]{2}$/, else None.

    The two-character cap matches `users.country_code VARCHAR(2)` —
    inserting a longer value would raise a `StringDataRightTruncation`
    rather than silently truncating.
    """
    if not code:
        return None
    cleaned = code.strip().upper()
    if not _CC_RE.match(cleaned):
        return None
    return cleaned


def _cache_get(ip: str) -> tuple[bool, str | None]:
    """Return (`hit?`, value). Distinguishes a cached-`None` (lookup
    failed previously) from a cache miss so we don't retry the upstream
    for an IP that's already known to be unresolvable."""
    if ip in _CACHE:
        return True, _CACHE[ip]
    return False, None


def _cache_put(ip: str, code: str | None) -> None:
    if len(_CACHE) >= _CACHE_MAX_ENTRIES:
        # Naive eviction — drop the oldest entry. dict preserves insertion
        # order in Python 3.7+, so popitem(last=False) via iter is fine.
        try:
            oldest = next(iter(_CACHE))
            _CACHE.pop(oldest, None)
        except StopIteration:  # pragma: no cover — cache empty under cap
            pass
    _CACHE[ip] = code


async def _lookup_via_ip_api(ip: str) -> str | None:
    """Single GET against `ip-api.com/json/{ip}`. Returns the
    `countryCode` field or None. Errors and timeouts are swallowed —
    auth must not 5xx because an external lookup is slow.

    Strictly server-side: never invoked from the client. Free tier of
    ip-api allows 45 req/min/IP, and because resolution is one-shot per
    user (then cached on `users.country_code`) we're nowhere near the
    cap in practice.
    """
    url = f"http://ip-api.com/json/{ip}?fields=status,countryCode"
    try:
        async with httpx.AsyncClient(timeout=_IP_API_TIMEOUT_SECONDS) as client:
            resp = await client.get(url)
            if resp.status_code != 200:
                return None
            data = resp.json()
    except (httpx.HTTPError, asyncio.TimeoutError, ValueError) as exc:
        log.debug("ip-api lookup failed for %s: %s", ip, exc)
        return None
    if (data.get("status") or "").lower() != "success":
        return None
    return _validate(data.get("countryCode"))


def _client_ip(request: Request) -> str | None:
    """Return the calling client's IP.

    Uvicorn runs with `--proxy-headers --forwarded-allow-ips=*` so
    `request.client.host` is already the real remote IP (X-Forwarded-For
    parsed upstream). Caddy puts the user's actual address there. The
    backend never sees the `127.0.0.1` of the Caddy → fastapi hop.
    """
    if request.client is None:
        return None
    return request.client.host


async def resolve_country_code(request: Request) -> str | None:
    """Best-effort resolution of the calling user's country.

    Order:
      1. `X-Country-Code` header (Caddy plugin). Constant time, no I/O.
      2. ip-api fallback on the request IP, cached.

    Returns an uppercase ISO 3166-1 alpha-2 code or `None`. Callers
    persist on first success; this function makes no DB writes itself.
    """
    # Header wins — if Caddy resolved it, we trust the answer and skip
    # the outbound call entirely. Header names are case-insensitive in
    # FastAPI's `Headers` mapping.
    header_value = request.headers.get(_HEADER_NAME)
    by_header = _validate(header_value)
    if by_header is not None:
        return by_header

    ip = _client_ip(request)
    if not ip:
        return None
    # Loopback / link-local won't geolocate — short-circuit so a local
    # dev request doesn't burn an ip-api call (which would return
    # "country for the public egress IP of the dev box", not the user's).
    if ip.startswith(("127.", "10.", "192.168.", "172.16.", "169.254.")) or ip == "::1":
        return None

    hit, cached = _cache_get(ip)
    if hit:
        return cached
    resolved = await _lookup_via_ip_api(ip)
    _cache_put(ip, resolved)
    return resolved


__all__ = ["resolve_country_code"]
