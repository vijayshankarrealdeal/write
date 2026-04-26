"""`.inkx` container packer + unpacker (server-side ground truth).

File layout (network byte order throughout)::

    +----------------------------------------+
    | magic        b"INKX"      4 bytes      |
    | version      u8           1 byte       |  // 0x01
    | flags        u8           1 byte       |  // bit 0: compressed (unused for now)
    | license_sig  64 bytes                  |  // raw Ed25519 signature, surfaced
    |                                        |  // in plaintext so book_key can be
    |                                        |  // derived without first decrypting
    |                                        |  // the header.
    | header_len   u32          4 bytes      |
    | header_blob  header_len bytes          |  // AES-GCM(book_key, JSON header)
    | chunk_blobs  ...                       |  // concatenated AES-GCM chunks
    | trailer_hmac 32 bytes                  |  // HMAC-SHA256 over all preceding
    |                                        |  // bytes, key=book_key
    +----------------------------------------+

Where each AES-GCM blob is ``nonce(12) || ciphertext || tag(16)``.

The header (after decryption) is JSON describing the chunk offset table
and which section / image lives in which chunk:

.. code-block:: json

    {
      "v": 1,
      "book_id": "<uuid>",
      "title": "...",
      "author": "...",
      "author_id": "<uuid>",
      "license": {<full LicensePayload + server_signature>},
      "sections": [{"id": "...", "title": "...", "section_index": 0, "chunk_index": 0}],
      "images":   [{"id": "...", "mime": "image/jpeg", "chunk_index": 1}],
      "chunks":   [{"offset": 0, "length": 1234}],   // offsets are relative to the
                                                     // start-of-chunks region
      "embedding_version": 1
    }

`book_key` is derived per-open as
``HKDF-SHA256(ikm = device_key || book_id_bytes, salt = license_sig[:16],
info = b"inkx-v1", length = 32)``. It is never persisted.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import struct
import uuid
from dataclasses import dataclass
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


MAGIC = b"INKX"
VERSION = 1
HEADER_PREFIX_LEN = 4 + 1 + 1 + 64 + 4  # magic + ver + flags + sig + header_len
NONCE_LEN = 12
GCM_TAG_LEN = 16
HMAC_LEN = 32
ED25519_SIG_LEN = 64
HKDF_INFO = b"inkx-v1"


class InkxError(ValueError):
    """Raised on any malformed / tampered / wrong-key `.inkx` file."""


@dataclass(frozen=True)
class SectionInput:
    """One section to pack. ``content`` is the JSONB blob the API serves."""

    id: str
    title: str
    section_index: int
    content: Any  # whatever was in feed_items.sections[i] / writings.sections[i]


@dataclass(frozen=True)
class ImageInput:
    id: str
    mime: str
    data: bytes
    blurhash: str | None = None


@dataclass(frozen=True)
class InkxBook:
    """Decoded contents — what the Flutter codec will mirror."""

    book_id: str
    title: str
    author: str
    author_id: str
    license: dict[str, Any]
    sections: list[dict[str, Any]]  # decrypted plaintext sections
    images: list[dict[str, Any]]  # decrypted plaintext images (data is bytes)
    embedding_version: int


def derive_book_key(
    *,
    device_key: bytes,
    book_id: str,
    license_signature: bytes,
) -> bytes:
    """HKDF-SHA256 — see module docstring.

    `device_key` is 32 bytes generated once at install on the client and
    stored in the platform secure enclave. The server never sees it; the
    server simply takes whatever the client supplies as part of the
    encode call (test path) — production encodes happen on the *server*
    in response to a download request, which means the server needs to
    use the same `device_key` the client will use to decode.

    The reconciliation: ``POST /api/offline/license`` accepts the
    client's `device_key` (or a key wrap of it) as part of the request,
    the packager uses it to encrypt, and it is *not* persisted. This is
    the only point at which the server holds it. Subsequent decodes on
    the device do not require server contact.
    """
    if len(device_key) != 32:
        raise InkxError(f"device_key must be 32 bytes, got {len(device_key)}")
    if len(license_signature) < 16:
        raise InkxError("license_signature must be at least 16 bytes")
    book_uuid_bytes = uuid.UUID(book_id).bytes
    return HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=license_signature[:16],
        info=HKDF_INFO,
    ).derive(device_key + book_uuid_bytes)


def _encrypt_chunk(book_key: bytes, plaintext: bytes) -> bytes:
    """AES-256-GCM. Returns ``nonce || ct || tag``."""
    aesgcm = AESGCM(book_key)
    nonce = os.urandom(NONCE_LEN)
    ct_with_tag = aesgcm.encrypt(nonce, plaintext, None)
    return nonce + ct_with_tag


def _decrypt_chunk(book_key: bytes, blob: bytes) -> bytes:
    if len(blob) < NONCE_LEN + GCM_TAG_LEN:
        raise InkxError("chunk too short")
    aesgcm = AESGCM(book_key)
    nonce = blob[:NONCE_LEN]
    ct_with_tag = blob[NONCE_LEN:]
    try:
        return aesgcm.decrypt(nonce, ct_with_tag, None)
    except InvalidTag as exc:
        raise InkxError("chunk decryption failed (wrong key or tampered ciphertext)") from exc


def pack_book(
    *,
    book_id: str,
    title: str,
    author: str,
    author_id: str,
    sections: list[SectionInput],
    images: list[ImageInput],
    license_obj: dict[str, Any],
    license_signature: bytes,
    device_key: bytes,
    embedding_version: int = 1,
) -> bytes:
    """Encode a book into a complete `.inkx` byte string.

    `license_obj` should be the dict returned by
    :func:`app.offline.license.issue_license`; `license_signature` is
    the raw signature bytes returned alongside it. They must agree —
    this function checks that ``license_obj["server_signature"]`` is
    the base64 of `license_signature` and rejects mismatches.
    """
    import base64

    expected_b64 = base64.b64encode(license_signature).decode("ascii")
    if license_obj.get("server_signature") != expected_b64:
        raise InkxError("license_obj.server_signature does not match license_signature bytes")
    if len(license_signature) != ED25519_SIG_LEN:
        raise InkxError(f"license_signature must be {ED25519_SIG_LEN} bytes")
    if license_obj.get("book_id") != book_id:
        raise InkxError("license_obj.book_id does not match book_id")

    book_key = derive_book_key(
        device_key=device_key,
        book_id=book_id,
        license_signature=license_signature,
    )

    # 1. Encrypt every section + image into its own chunk. One chunk per
    # piece keeps lazy decryption simple — the reader decrypts only the
    # chunks for sections it actually opens.
    chunk_blobs: list[bytes] = []
    section_meta: list[dict[str, Any]] = []
    for s in sections:
        section_pt = json.dumps(
            {
                "id": s.id,
                "title": s.title,
                "section_index": s.section_index,
                "content": s.content,
            },
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
        chunk_blobs.append(_encrypt_chunk(book_key, section_pt))
        section_meta.append({
            "id": s.id,
            "title": s.title,
            "section_index": s.section_index,
            "chunk_index": len(chunk_blobs) - 1,
        })

    image_meta: list[dict[str, Any]] = []
    for img in images:
        chunk_blobs.append(_encrypt_chunk(book_key, img.data))
        image_meta.append({
            "id": img.id,
            "mime": img.mime,
            "blurhash": img.blurhash,
            "chunk_index": len(chunk_blobs) - 1,
        })

    # 2. Build the chunk offset table (relative to start-of-chunks).
    chunk_table = []
    rel = 0
    for blob in chunk_blobs:
        chunk_table.append({"offset": rel, "length": len(blob)})
        rel += len(blob)

    # 3. Build + encrypt the header.
    header = {
        "v": VERSION,
        "book_id": book_id,
        "title": title,
        "author": author,
        "author_id": author_id,
        "license": license_obj,
        "sections": section_meta,
        "images": image_meta,
        "chunks": chunk_table,
        "embedding_version": embedding_version,
    }
    header_pt = json.dumps(header, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    header_blob = _encrypt_chunk(book_key, header_pt)

    # 4. Assemble.
    flags = 0
    file_prefix = (
        MAGIC
        + struct.pack(">B", VERSION)
        + struct.pack(">B", flags)
        + license_signature
        + struct.pack(">I", len(header_blob))
        + header_blob
    )
    body = file_prefix + b"".join(chunk_blobs)
    mac = hmac.new(book_key, body, hashlib.sha256).digest()
    return body + mac


def unpack_book(
    data: bytes,
    *,
    device_key: bytes,
    expected_book_id: str | None = None,
) -> InkxBook:
    """Decode a `.inkx` byte string. Verifies HMAC + every GCM tag.

    Pass ``expected_book_id`` to bind decryption to a specific book —
    if the file's ``book_id`` doesn't match, decode fails before any
    plaintext is exposed (the HKDF input differs, so the GCM tag
    verification trips).
    """
    if len(data) < HEADER_PREFIX_LEN + GCM_TAG_LEN + NONCE_LEN + HMAC_LEN:
        raise InkxError("file too short to be a valid .inkx")

    if data[:4] != MAGIC:
        raise InkxError("bad magic; not an .inkx file")
    version = data[4]
    if version != VERSION:
        raise InkxError(f"unsupported version {version}")
    # flags = data[5]  # currently unused
    license_signature = data[6:6 + ED25519_SIG_LEN]
    header_len = struct.unpack(">I", data[6 + ED25519_SIG_LEN:HEADER_PREFIX_LEN])[0]

    chunks_start = HEADER_PREFIX_LEN + header_len
    body_end = len(data) - HMAC_LEN
    if chunks_start > body_end:
        raise InkxError("header overruns file")

    header_blob = data[HEADER_PREFIX_LEN:chunks_start]
    chunks_blob = data[chunks_start:body_end]
    file_mac = data[body_end:]

    book_id_for_kdf = expected_book_id
    if book_id_for_kdf is None:
        # Decode requires the book_id up front because it's part of the
        # KDF input. Without expected_book_id we'd have to trust the
        # header's claimed id, which the GCM tag protects but only
        # *after* we successfully decrypt with the right key — circular.
        raise InkxError("expected_book_id is required to unpack a .inkx file")

    book_key = derive_book_key(
        device_key=device_key,
        book_id=book_id_for_kdf,
        license_signature=license_signature,
    )

    expected_mac = hmac.new(book_key, data[:body_end], hashlib.sha256).digest()
    if not hmac.compare_digest(expected_mac, file_mac):
        raise InkxError("HMAC verification failed (file tampered or wrong device)")

    header_pt = _decrypt_chunk(book_key, header_blob)
    header = json.loads(header_pt.decode("utf-8"))

    if header.get("book_id") != book_id_for_kdf:
        raise InkxError("header.book_id does not match expected_book_id")
    # Cross-check the in-file plaintext signature against the header copy.
    license_obj = header.get("license") or {}
    if license_obj.get("server_signature") is None:
        raise InkxError("header missing license.server_signature")
    import base64

    expected_b64 = base64.b64encode(license_signature).decode("ascii")
    if license_obj["server_signature"] != expected_b64:
        raise InkxError("plaintext license signature does not match header copy")

    chunk_table = header["chunks"]
    section_meta = header["sections"]
    image_meta = header["images"]

    def _read_chunk(idx: int) -> bytes:
        meta = chunk_table[idx]
        offset = meta["offset"]
        length = meta["length"]
        blob = chunks_blob[offset:offset + length]
        if len(blob) != length:
            raise InkxError(f"chunk {idx} truncated")
        return _decrypt_chunk(book_key, blob)

    decoded_sections: list[dict[str, Any]] = []
    for sm in section_meta:
        plain = _read_chunk(sm["chunk_index"])
        decoded_sections.append(json.loads(plain.decode("utf-8")))

    decoded_images: list[dict[str, Any]] = []
    for im in image_meta:
        plain = _read_chunk(im["chunk_index"])
        decoded_images.append({
            "id": im["id"],
            "mime": im["mime"],
            "blurhash": im.get("blurhash"),
            "data": plain,
        })

    return InkxBook(
        book_id=header["book_id"],
        title=header["title"],
        author=header["author"],
        author_id=header["author_id"],
        license=license_obj,
        sections=decoded_sections,
        images=decoded_images,
        embedding_version=header.get("embedding_version", 1),
    )
