"""Offline-reading license tokens.

A license binds `(user_id, device_id, book_id)` to a TTL. The server
holds an Ed25519 private key (env: ``INKX_LICENSE_SIGNING_KEY``); the
public half is bundled into the Flutter app and verifies signatures
client-side before any decryption is attempted.

Format (returned by :func:`issue_license`):

.. code-block:: json

    {
      "user_id": "<uuid>",
      "device_id": "<uuid>",
      "book_id": "<uuid>",
      "issued_at": <unix-seconds>,
      "expires_at": <unix-seconds>,
      "server_signature": "<base64-ed25519-sig over canonical json without `server_signature`>"
    }

The signature is computed over the canonical (sorted-keys, separators-fixed)
JSON of the payload *with the* ``server_signature`` *field omitted*, so
verification is symmetric: drop the field, re-canonicalise, verify.
"""

from __future__ import annotations

import base64
import json
import time
from dataclasses import dataclass
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
    PublicFormat,
)


# Default TTL — matches p2.md spec (30 days). Renewal flow re-issues
# inside a 7-day window before expiry.
DEFAULT_TTL_SECONDS = 30 * 24 * 60 * 60


class LicenseError(ValueError):
    """Raised for any license issuance / verification failure."""


@dataclass(frozen=True)
class LicensePayload:
    """Pre-signature license body. Pure data — no crypto state."""

    user_id: str
    device_id: str
    book_id: str
    issued_at: int
    expires_at: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "user_id": self.user_id,
            "device_id": self.device_id,
            "book_id": self.book_id,
            "issued_at": self.issued_at,
            "expires_at": self.expires_at,
        }

    @classmethod
    def now(
        cls,
        *,
        user_id: str,
        device_id: str,
        book_id: str,
        ttl_seconds: int = DEFAULT_TTL_SECONDS,
    ) -> "LicensePayload":
        issued = int(time.time())
        return cls(
            user_id=user_id,
            device_id=device_id,
            book_id=book_id,
            issued_at=issued,
            expires_at=issued + ttl_seconds,
        )


def _canonicalise(payload: dict[str, Any]) -> bytes:
    """Deterministic JSON encoding for signing.

    `sort_keys=True` and the explicit separators are what makes the
    bytes hashable across Python / Dart / any other implementation.
    """
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _load_private_key(seed_b64: str) -> Ed25519PrivateKey:
    """Load an Ed25519 private key from a base64-encoded 32-byte seed.

    Operators generate one with ``python -c 'import os, base64;
    print(base64.b64encode(os.urandom(32)).decode())'`` and set
    ``INKX_LICENSE_SIGNING_KEY`` to the result. Rotating the key
    invalidates all outstanding licenses; clients must re-acquire.
    """
    if not seed_b64:
        raise LicenseError(
            "INKX_LICENSE_SIGNING_KEY is not set. Offline downloads are disabled "
            "until an operator provisions a 32-byte base64 Ed25519 seed."
        )
    try:
        seed = base64.b64decode(seed_b64, validate=True)
    except Exception as exc:  # noqa: BLE001 — surface to caller verbatim
        raise LicenseError(f"INKX_LICENSE_SIGNING_KEY is not valid base64: {exc}") from exc
    if len(seed) != 32:
        raise LicenseError(
            f"INKX_LICENSE_SIGNING_KEY decoded to {len(seed)} bytes, expected 32"
        )
    return Ed25519PrivateKey.from_private_bytes(seed)


def public_key_b64(seed_b64: str) -> str:
    """Return the base64 public key matching ``seed_b64``.

    Used at app-build time to bundle the verification key into the
    Flutter binary; tests use it to verify what we just signed.
    """
    private = _load_private_key(seed_b64)
    public_bytes = private.public_key().public_bytes(
        encoding=Encoding.Raw,
        format=PublicFormat.Raw,
    )
    return base64.b64encode(public_bytes).decode("ascii")


def issue_license(
    payload: LicensePayload,
    *,
    signing_key_b64: str,
) -> tuple[dict[str, Any], bytes]:
    """Sign a payload, returning (json-serialisable license, raw signature bytes).

    The raw signature is also embedded in the JSON (base64). Returning
    it separately means the caller doesn't have to re-decode when it
    needs the bytes (the codec keys book derivation off ``sig[:16]``).
    """
    private = _load_private_key(signing_key_b64)
    body = payload.to_dict()
    canonical = _canonicalise(body)
    signature = private.sign(canonical)
    body["server_signature"] = base64.b64encode(signature).decode("ascii")
    return body, signature


def verify_license(
    license_obj: dict[str, Any],
    *,
    signing_key_b64: str | None = None,
    public_key_b64_str: str | None = None,
    now: int | None = None,
) -> bytes:
    """Validate signature + expiry. Return the raw signature bytes on success.

    Either ``signing_key_b64`` (server-side, derives the public key) or
    ``public_key_b64_str`` (client-side, uses a bundled public key) must
    be supplied. Raises :class:`LicenseError` on any failure.
    """
    if "server_signature" not in license_obj:
        raise LicenseError("license missing server_signature")
    body = {k: v for k, v in license_obj.items() if k != "server_signature"}
    canonical = _canonicalise(body)
    try:
        signature = base64.b64decode(license_obj["server_signature"], validate=True)
    except Exception as exc:  # noqa: BLE001
        raise LicenseError(f"server_signature is not valid base64: {exc}") from exc

    public: Ed25519PublicKey
    if signing_key_b64 is not None:
        public = _load_private_key(signing_key_b64).public_key()
    elif public_key_b64_str is not None:
        try:
            raw = base64.b64decode(public_key_b64_str, validate=True)
        except Exception as exc:  # noqa: BLE001
            raise LicenseError(f"public key is not valid base64: {exc}") from exc
        if len(raw) != 32:
            raise LicenseError("public key must be 32 raw bytes")
        public = Ed25519PublicKey.from_public_bytes(raw)
    else:
        raise LicenseError("verify_license requires a signing_key_b64 or public_key_b64_str")

    try:
        public.verify(signature, canonical)
    except InvalidSignature as exc:
        raise LicenseError("license signature is invalid") from exc

    expires_at = license_obj.get("expires_at")
    if not isinstance(expires_at, int):
        raise LicenseError("license missing integer expires_at")
    nowts = int(time.time()) if now is None else now
    if expires_at <= nowts:
        raise LicenseError("license has expired")

    return signature


# ---------------------------------------------------------------------------
# Test helpers (pure data; importable from app code so tests don't have to
# poke at the private key path).
# ---------------------------------------------------------------------------


def generate_signing_key_b64() -> str:
    """Generate a fresh Ed25519 seed encoded as base64.

    Used by tests + by operators bootstrapping a deployment; never
    called at request time.
    """
    private = Ed25519PrivateKey.generate()
    raw = private.private_bytes(
        encoding=Encoding.Raw,
        format=PrivateFormat.Raw,
        encryption_algorithm=NoEncryption(),
    )
    return base64.b64encode(raw).decode("ascii")
