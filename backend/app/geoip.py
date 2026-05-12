"""IP-to-country lookup for the admin region breakdown.

The client used to report `properties.region` derived from the device
locale (e.g. en_US -> "US"). That made the admin "User regions" chart
useless: anyone whose phone shipped with en_US as the default — which
is most non-localised English speakers worldwide — was bucketed as US.

This module resolves the request IP to a country at admin-query time
and caches the result in Redis. Lookups go through api.country.is, a
free no-auth service that returns ``{"ip": "...", "country": "XX"}``.
We cache positive hits for 30 days and negative results for 1 hour so
a transient API hiccup doesn't lock in "unknown" forever.
"""
from __future__ import annotations

import asyncio
import ipaddress
from typing import Iterable

import httpx

from app.config import settings
from app.logger import get_logger

log = get_logger("app.geoip")

_CACHE_PREFIX = "geoip:country:"
_CACHE_TTL_SECONDS = 30 * 24 * 3600
_NEGATIVE_TTL_SECONDS = 3600
_NEGATIVE_SENTINEL = "_"
_HTTP_TIMEOUT = 2.0
_MAX_CONCURRENT_LOOKUPS = 8


def _is_public(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return not (
        addr.is_private
        or addr.is_loopback
        or addr.is_link_local
        or addr.is_multicast
        or addr.is_unspecified
        or addr.is_reserved
    )


async def _lookup_one(client: httpx.AsyncClient, ip: str) -> str | None:
    try:
        r = await client.get(f"https://api.country.is/{ip}", timeout=_HTTP_TIMEOUT)
        if r.status_code == 200:
            cc = (r.json().get("country") or "").upper()
            return cc if len(cc) == 2 and cc.isalpha() else None
    except Exception as exc:
        log.debug("geoip lookup failed for %s: %s", ip, exc)
    return None


async def countries_for_ips(ips: Iterable[str]) -> dict[str, str | None]:
    """Resolve each IP to a 2-letter country code.

    Returns a dict keyed by the input IP. Values are ``None`` for
    private/invalid IPs or when the upstream lookup failed. Public IPs
    not in cache are looked up concurrently (bounded fan-out) and
    written back to Redis."""
    uniq = sorted({ip for ip in ips if ip})
    out: dict[str, str | None] = {}
    if not uniq:
        return out

    redis = None
    if settings.redis_url:
        from redis import asyncio as redis_asyncio

        redis = redis_asyncio.from_url(settings.redis_url, decode_responses=True)

    try:
        to_lookup: list[str] = []
        if redis is not None:
            cached = await redis.mget([_CACHE_PREFIX + ip for ip in uniq])
            for ip, val in zip(uniq, cached):
                if val is None:
                    if _is_public(ip):
                        to_lookup.append(ip)
                    else:
                        out[ip] = None
                else:
                    out[ip] = None if val == _NEGATIVE_SENTINEL else val
        else:
            for ip in uniq:
                if _is_public(ip):
                    to_lookup.append(ip)
                else:
                    out[ip] = None

        if to_lookup:
            sem = asyncio.Semaphore(_MAX_CONCURRENT_LOOKUPS)

            async def _one(client: httpx.AsyncClient, ip: str) -> None:
                async with sem:
                    cc = await _lookup_one(client, ip)
                out[ip] = cc
                if redis is not None:
                    if cc:
                        await redis.set(_CACHE_PREFIX + ip, cc, ex=_CACHE_TTL_SECONDS)
                    else:
                        await redis.set(
                            _CACHE_PREFIX + ip, _NEGATIVE_SENTINEL, ex=_NEGATIVE_TTL_SECONDS
                        )

            async with httpx.AsyncClient() as client:
                await asyncio.gather(*(_one(client, ip) for ip in to_lookup))

        return out
    finally:
        if redis is not None:
            await redis.aclose()
