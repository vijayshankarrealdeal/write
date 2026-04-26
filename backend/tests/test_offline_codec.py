"""Round-trip + tampering tests for the `.inkx` codec.

Pure unit tests — no Postgres, no HTTP. The packager + license
modules are pure functions; these tests pin their behaviour so the
file format can't drift accidentally.
"""

from __future__ import annotations

import base64
import os
import time
import uuid

import pytest

from app.offline import license as inkx_license
from app.offline import packager as inkx_packager


@pytest.fixture
def signing_key() -> str:
    return inkx_license.generate_signing_key_b64()


@pytest.fixture
def device_key() -> bytes:
    return os.urandom(32)


def _make_payload(*, ttl: int = 3600) -> tuple[inkx_license.LicensePayload, str]:
    book_id = str(uuid.uuid4())
    payload = inkx_license.LicensePayload.now(
        user_id=str(uuid.uuid4()),
        device_id=str(uuid.uuid4()),
        book_id=book_id,
        ttl_seconds=ttl,
    )
    return payload, book_id


def _roundtrip_inputs(book_id: str):
    sections = [
        inkx_packager.SectionInput(
            id="sec-1",
            title="Chapter 1",
            section_index=0,
            content={"id": "sec-1", "ops": [{"insert": "Hello world"}]},
        ),
        inkx_packager.SectionInput(
            id="sec-2",
            title="Chapter 2",
            section_index=1,
            content={"id": "sec-2", "ops": [{"insert": "Second chapter"}]},
        ),
    ]
    images = [
        inkx_packager.ImageInput(
            id="img-1",
            mime="image/jpeg",
            data=b"\xff\xd8\xff\xe0fakejpeg",
            blurhash="L9AS}u%MfQfQfQfQfQfQ",
        ),
    ]
    return sections, images


def test_roundtrip_pack_then_unpack(signing_key, device_key):
    payload, book_id = _make_payload()
    license_obj, sig = inkx_license.issue_license(payload, signing_key_b64=signing_key)
    sections, images = _roundtrip_inputs(book_id)

    blob = inkx_packager.pack_book(
        book_id=book_id,
        title="Test Book",
        author="Test Author",
        author_id=str(uuid.uuid4()),
        sections=sections,
        images=images,
        license_obj=license_obj,
        license_signature=sig,
        device_key=device_key,
    )

    decoded = inkx_packager.unpack_book(
        blob, device_key=device_key, expected_book_id=book_id
    )
    assert decoded.book_id == book_id
    assert decoded.title == "Test Book"
    assert len(decoded.sections) == 2
    assert decoded.sections[0]["title"] == "Chapter 1"
    assert decoded.sections[1]["section_index"] == 1
    assert decoded.images[0]["data"] == b"\xff\xd8\xff\xe0fakejpeg"
    assert decoded.images[0]["blurhash"] == "L9AS}u%MfQfQfQfQfQfQ"
    assert decoded.license["user_id"] == payload.user_id


def test_magic_byte_tampering_rejected(signing_key, device_key):
    payload, book_id = _make_payload()
    license_obj, sig = inkx_license.issue_license(payload, signing_key_b64=signing_key)
    sections, _ = _roundtrip_inputs(book_id)
    blob = inkx_packager.pack_book(
        book_id=book_id, title="t", author="a", author_id=str(uuid.uuid4()),
        sections=sections, images=[], license_obj=license_obj,
        license_signature=sig, device_key=device_key,
    )
    bad = b"XXXX" + blob[4:]
    with pytest.raises(inkx_packager.InkxError, match="bad magic"):
        inkx_packager.unpack_book(bad, device_key=device_key, expected_book_id=book_id)


def test_hmac_tampering_rejected(signing_key, device_key):
    payload, book_id = _make_payload()
    license_obj, sig = inkx_license.issue_license(payload, signing_key_b64=signing_key)
    sections, _ = _roundtrip_inputs(book_id)
    blob = inkx_packager.pack_book(
        book_id=book_id, title="t", author="a", author_id=str(uuid.uuid4()),
        sections=sections, images=[], license_obj=license_obj,
        license_signature=sig, device_key=device_key,
    )
    # Flip the last byte of the HMAC trailer.
    bad = blob[:-1] + bytes([blob[-1] ^ 0xFF])
    with pytest.raises(inkx_packager.InkxError, match="HMAC"):
        inkx_packager.unpack_book(bad, device_key=device_key, expected_book_id=book_id)


def test_wrong_device_key_rejected(signing_key, device_key):
    payload, book_id = _make_payload()
    license_obj, sig = inkx_license.issue_license(payload, signing_key_b64=signing_key)
    sections, _ = _roundtrip_inputs(book_id)
    blob = inkx_packager.pack_book(
        book_id=book_id, title="t", author="a", author_id=str(uuid.uuid4()),
        sections=sections, images=[], license_obj=license_obj,
        license_signature=sig, device_key=device_key,
    )
    other_key = os.urandom(32)
    # Wrong key trips HMAC first (book_key disagrees with what the
    # file was signed under), so the user never sees a partial decrypt.
    with pytest.raises(inkx_packager.InkxError, match="HMAC"):
        inkx_packager.unpack_book(blob, device_key=other_key, expected_book_id=book_id)


def test_wrong_book_id_rejected(signing_key, device_key):
    payload, book_id = _make_payload()
    license_obj, sig = inkx_license.issue_license(payload, signing_key_b64=signing_key)
    sections, _ = _roundtrip_inputs(book_id)
    blob = inkx_packager.pack_book(
        book_id=book_id, title="t", author="a", author_id=str(uuid.uuid4()),
        sections=sections, images=[], license_obj=license_obj,
        license_signature=sig, device_key=device_key,
    )
    other_book_id = str(uuid.uuid4())
    with pytest.raises(inkx_packager.InkxError):
        inkx_packager.unpack_book(
            blob, device_key=device_key, expected_book_id=other_book_id
        )


def test_chunk_ciphertext_tampering_rejected(signing_key, device_key):
    payload, book_id = _make_payload()
    license_obj, sig = inkx_license.issue_license(payload, signing_key_b64=signing_key)
    sections, _ = _roundtrip_inputs(book_id)
    blob = inkx_packager.pack_book(
        book_id=book_id, title="t", author="a", author_id=str(uuid.uuid4()),
        sections=sections, images=[], license_obj=license_obj,
        license_signature=sig, device_key=device_key,
    )
    # Flip a byte inside the chunks region. Walk past the header to
    # find a chunk byte — chunks_start = HEADER_PREFIX_LEN + header_len.
    import struct
    header_len = struct.unpack(">I", blob[6 + 64:6 + 64 + 4])[0]
    chunks_start = inkx_packager.HEADER_PREFIX_LEN + header_len
    # Tamper one byte well after the chunk's nonce so the HMAC trips
    # before the GCM tag would.
    pos = chunks_start + 32
    bad = blob[:pos] + bytes([blob[pos] ^ 0x55]) + blob[pos + 1:]
    with pytest.raises(inkx_packager.InkxError):
        inkx_packager.unpack_book(bad, device_key=device_key, expected_book_id=book_id)


def test_license_signature_verifies(signing_key):
    payload, _ = _make_payload()
    license_obj, sig = inkx_license.issue_license(payload, signing_key_b64=signing_key)
    # Returned signature bytes match the base64 in the JSON.
    assert base64.b64encode(sig).decode("ascii") == license_obj["server_signature"]
    # And re-verify via the public key derived from the same seed.
    inkx_license.verify_license(license_obj, signing_key_b64=signing_key)


def test_license_tampered_field_rejected(signing_key):
    payload, _ = _make_payload()
    license_obj, _ = inkx_license.issue_license(payload, signing_key_b64=signing_key)
    license_obj["expires_at"] += 1  # flip a single field
    with pytest.raises(inkx_license.LicenseError, match="invalid"):
        inkx_license.verify_license(license_obj, signing_key_b64=signing_key)


def test_license_expired_rejected(signing_key):
    payload, _ = _make_payload(ttl=60)
    license_obj, _ = inkx_license.issue_license(payload, signing_key_b64=signing_key)
    # Pretend the clock is well after expiry.
    future = license_obj["expires_at"] + 10
    with pytest.raises(inkx_license.LicenseError, match="expired"):
        inkx_license.verify_license(
            license_obj, signing_key_b64=signing_key, now=future
        )


def test_license_verify_with_public_key_only(signing_key):
    """Mirrors what the Flutter codec will do — verify without the seed."""
    public = inkx_license.public_key_b64(signing_key)
    payload, _ = _make_payload()
    license_obj, _ = inkx_license.issue_license(payload, signing_key_b64=signing_key)
    inkx_license.verify_license(license_obj, public_key_b64_str=public)


def test_pack_rejects_mismatched_license_signature(signing_key, device_key):
    payload, book_id = _make_payload()
    license_obj, sig = inkx_license.issue_license(payload, signing_key_b64=signing_key)
    sections, _ = _roundtrip_inputs(book_id)
    # Pass *different* signature bytes than what's encoded in license_obj.
    other_sig = b"\x00" * 64
    with pytest.raises(inkx_packager.InkxError, match="server_signature"):
        inkx_packager.pack_book(
            book_id=book_id, title="t", author="a", author_id=str(uuid.uuid4()),
            sections=sections, images=[], license_obj=license_obj,
            license_signature=other_sig, device_key=device_key,
        )


def test_pack_rejects_book_id_mismatch(signing_key, device_key):
    payload, book_id = _make_payload()
    license_obj, sig = inkx_license.issue_license(payload, signing_key_b64=signing_key)
    sections, _ = _roundtrip_inputs(book_id)
    other_book_id = str(uuid.uuid4())
    with pytest.raises(inkx_packager.InkxError, match="book_id"):
        inkx_packager.pack_book(
            book_id=other_book_id,  # disagrees with license.book_id
            title="t", author="a", author_id=str(uuid.uuid4()),
            sections=sections, images=[], license_obj=license_obj,
            license_signature=sig, device_key=device_key,
        )


def test_unpack_requires_expected_book_id(signing_key, device_key):
    payload, book_id = _make_payload()
    license_obj, sig = inkx_license.issue_license(payload, signing_key_b64=signing_key)
    sections, _ = _roundtrip_inputs(book_id)
    blob = inkx_packager.pack_book(
        book_id=book_id, title="t", author="a", author_id=str(uuid.uuid4()),
        sections=sections, images=[], license_obj=license_obj,
        license_signature=sig, device_key=device_key,
    )
    with pytest.raises(inkx_packager.InkxError, match="expected_book_id"):
        inkx_packager.unpack_book(blob, device_key=device_key)


def test_signing_key_loader_rejects_short_seed():
    with pytest.raises(inkx_license.LicenseError, match="32"):
        inkx_license.public_key_b64(base64.b64encode(b"too-short").decode("ascii"))


def test_signing_key_loader_requires_value():
    with pytest.raises(inkx_license.LicenseError, match="not set"):
        inkx_license.public_key_b64("")
