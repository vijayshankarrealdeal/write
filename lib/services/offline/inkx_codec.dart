/// Flutter mirror of `backend/app/offline/packager.py`.
///
/// File layout (network byte order):
///
///     +----------------------------------------+
///     | magic        "INKX"       4 bytes      |
///     | version      u8           1 byte       |  // 0x01
///     | flags        u8           1 byte       |
///     | license_sig  64 bytes                  |  // raw Ed25519, plaintext
///     | header_len   u32          4 bytes      |
///     | header_blob  header_len bytes          |  // AES-GCM(book_key, JSON)
///     | chunk_blobs  ...                       |
///     | trailer_hmac 32 bytes                  |  // HMAC-SHA256, key=book_key
///     +----------------------------------------+
///
/// Each AES-GCM blob is `nonce(12) || ciphertext || tag(16)`.
///
/// `book_key = HKDF-SHA256(device_key || uuidBytes(book_id),
///                          salt=license_sig[:16], info="inkx-v1", L=32)`
///
/// Section chunks decrypt lazily — the reader calls [InkxBook.readSection]
/// with an index and only that chunk hits AES.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const _magic = <int>[0x49, 0x4E, 0x4B, 0x58]; // "INKX"
const int _version = 1;
const int _nonceLen = 12;
const int _gcmTagLen = 16;
const int _hmacLen = 32;
const int _ed25519SigLen = 64;
const int _headerPrefixLen = 4 + 1 + 1 + 64 + 4;
final List<int> _hkdfInfo = utf8.encode('inkx-v1');

class InkxError implements Exception {
  InkxError(this.message);
  final String message;
  @override
  String toString() => 'InkxError: $message';
}

/// Thin metadata view of a section without decrypting its content.
class InkxSectionMeta {
  InkxSectionMeta({
    required this.id,
    required this.title,
    required this.sectionIndex,
    required this.chunkIndex,
  });

  final String id;
  final String title;
  final int sectionIndex;
  final int chunkIndex;
}

class InkxImageMeta {
  InkxImageMeta({
    required this.id,
    required this.mime,
    required this.blurhash,
    required this.chunkIndex,
  });

  final String id;
  final String mime;
  final String? blurhash;
  final int chunkIndex;
}

/// Decoded book handle. Owns the byte buffer + derived `book_key` and
/// exposes lazy decrypt accessors so we never hold the full plaintext
/// in memory at once.
class InkxBook {
  InkxBook._({
    required Uint8List bytes,
    required SecretKey bookKey,
    required this.bookId,
    required this.title,
    required this.author,
    required this.authorId,
    required this.license,
    required this.sections,
    required this.images,
    required this.embeddingVersion,
    required List<_ChunkOffset> chunkTable,
    required int chunksStart,
  })  : _bytes = bytes,
        _bookKey = bookKey,
        _chunkTable = chunkTable,
        _chunksStart = chunksStart;

  final Uint8List _bytes;
  final SecretKey _bookKey;
  final List<_ChunkOffset> _chunkTable;
  final int _chunksStart;

  final String bookId;
  final String title;
  final String author;
  final String authorId;
  final Map<String, dynamic> license;
  final List<InkxSectionMeta> sections;
  final List<InkxImageMeta> images;
  final int embeddingVersion;

  /// Decrypt and return the full content of [sectionIndex] (UTF-8 JSON).
  Future<Map<String, dynamic>> readSection(int sectionIndex) async {
    if (sectionIndex < 0 || sectionIndex >= sections.length) {
      throw InkxError('section index out of range: $sectionIndex');
    }
    final meta = sections[sectionIndex];
    final pt = await _readChunk(meta.chunkIndex);
    final obj = jsonDecode(utf8.decode(pt));
    if (obj is! Map<String, dynamic>) {
      throw InkxError('section $sectionIndex did not decode to an object');
    }
    return obj;
  }

  /// Decrypt and return the bytes for image [imageId].
  Future<Uint8List> readImage(String imageId) async {
    final meta = images.firstWhere(
      (m) => m.id == imageId,
      orElse: () => throw InkxError('image not found: $imageId'),
    );
    return _readChunk(meta.chunkIndex);
  }

  Future<Uint8List> _readChunk(int idx) async {
    if (idx < 0 || idx >= _chunkTable.length) {
      throw InkxError('chunk index out of range: $idx');
    }
    final offset = _chunkTable[idx].offset;
    final length = _chunkTable[idx].length;
    if (length < _nonceLen + _gcmTagLen) {
      throw InkxError('chunk $idx too short');
    }
    final start = _chunksStart + offset;
    final end = start + length;
    if (end > _bytes.length - _hmacLen) {
      throw InkxError('chunk $idx overruns file');
    }
    final blob = _bytes.sublist(start, end);
    return _aesGcmDecrypt(_bookKey, blob);
  }
}

class _ChunkOffset {
  _ChunkOffset(this.offset, this.length);
  final int offset;
  final int length;
}

/// Derive the per-book AES key. Mirrors [`derive_book_key` in packager.py].
Future<SecretKey> deriveBookKey({
  required List<int> deviceKey,
  required String bookId,
  required List<int> licenseSignature,
}) async {
  if (deviceKey.length != 32) {
    throw InkxError('device_key must be 32 bytes, got ${deviceKey.length}');
  }
  if (licenseSignature.length < 16) {
    throw InkxError('license_signature must be at least 16 bytes');
  }
  final uuidBytes = _uuidStringToBytes(bookId);
  final ikm = <int>[...deviceKey, ...uuidBytes];
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final derived = await hkdf.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: licenseSignature.sublist(0, 16),
    info: _hkdfInfo,
  );
  return derived;
}

/// Decode a `.inkx` byte string. Verifies HMAC, license signature against
/// the bundled public key, and the GCM tag of the header.
///
/// Section + image chunks are *not* eagerly decrypted — call
/// [InkxBook.readSection] / [InkxBook.readImage] when needed.
Future<InkxBook> decodeInkx(
  Uint8List data, {
  required List<int> deviceKey,
  required String expectedBookId,
  required List<int> licensePublicKey,
}) async {
  if (data.length < _headerPrefixLen + _gcmTagLen + _nonceLen + _hmacLen) {
    throw InkxError('file too short to be a valid .inkx');
  }
  for (var i = 0; i < _magic.length; i++) {
    if (data[i] != _magic[i]) {
      throw InkxError('bad magic; not an .inkx file');
    }
  }
  final version = data[4];
  if (version != _version) {
    throw InkxError('unsupported version $version');
  }
  // flags = data[5]; — unused
  final licenseSig = data.sublist(6, 6 + _ed25519SigLen);
  final headerLen = ByteData.sublistView(
    data,
    6 + _ed25519SigLen,
    _headerPrefixLen,
  ).getUint32(0, Endian.big);

  final chunksStart = _headerPrefixLen + headerLen;
  final bodyEnd = data.length - _hmacLen;
  if (chunksStart > bodyEnd) {
    throw InkxError('header overruns file');
  }
  final headerBlob = data.sublist(_headerPrefixLen, chunksStart);
  final fileMac = data.sublist(bodyEnd);

  final bookKey = await deriveBookKey(
    deviceKey: deviceKey,
    bookId: expectedBookId,
    licenseSignature: licenseSig,
  );

  // 1. HMAC trailer first — cheapest check; trips on wrong device key
  // before any GCM tag verification reveals plaintext.
  final macAlgo = Hmac.sha256();
  final expectedMac = await macAlgo.calculateMac(
    data.sublist(0, bodyEnd),
    secretKey: bookKey,
  );
  if (!_constantTimeEquals(expectedMac.bytes, fileMac)) {
    throw InkxError('HMAC verification failed (file tampered or wrong device)');
  }

  // 2. Decrypt header.
  final headerPt = await _aesGcmDecrypt(bookKey, headerBlob);
  final header = jsonDecode(utf8.decode(headerPt));
  if (header is! Map<String, dynamic>) {
    throw InkxError('header did not decode to an object');
  }
  if (header['book_id'] != expectedBookId) {
    throw InkxError('header.book_id does not match expected_book_id');
  }
  final licenseObj = header['license'];
  if (licenseObj is! Map<String, dynamic>) {
    throw InkxError('header missing license');
  }
  final headerSig = licenseObj['server_signature'];
  if (headerSig is! String) {
    throw InkxError('header missing license.server_signature');
  }
  if (headerSig != base64.encode(licenseSig)) {
    throw InkxError('plaintext license signature does not match header copy');
  }

  // 3. Verify the license signature against the bundled public key.
  await _verifyLicenseSignature(
    licenseObj: licenseObj,
    signatureBytes: licenseSig,
    publicKey: licensePublicKey,
  );

  // 4. Build chunk + section + image tables. Sections / images are NOT
  // decrypted here; the caller does that on demand.
  final chunksRaw = (header['chunks'] as List).cast<Map>();
  final chunkTable = chunksRaw
      .map((m) => _ChunkOffset(m['offset'] as int, m['length'] as int))
      .toList(growable: false);

  final sectionMetas = (header['sections'] as List)
      .cast<Map>()
      .map((m) => InkxSectionMeta(
            id: m['id'] as String,
            title: (m['title'] as String?) ?? '',
            sectionIndex: m['section_index'] as int,
            chunkIndex: m['chunk_index'] as int,
          ))
      .toList(growable: false);

  final imageMetas = (header['images'] as List? ?? const [])
      .cast<Map>()
      .map((m) => InkxImageMeta(
            id: m['id'] as String,
            mime: (m['mime'] as String?) ?? 'application/octet-stream',
            blurhash: m['blurhash'] as String?,
            chunkIndex: m['chunk_index'] as int,
          ))
      .toList(growable: false);

  return InkxBook._(
    bytes: data,
    bookKey: bookKey,
    bookId: expectedBookId,
    title: (header['title'] as String?) ?? '',
    author: (header['author'] as String?) ?? '',
    authorId: (header['author_id'] as String?) ?? '',
    license: Map<String, dynamic>.from(licenseObj),
    sections: sectionMetas,
    images: imageMetas,
    embeddingVersion: (header['embedding_version'] as int?) ?? 1,
    chunkTable: chunkTable,
    chunksStart: chunksStart,
  );
}

/// Encode a `.inkx` byte string. The server is the canonical encoder in
/// production; this lives in the client package only to power tests
/// (round-trip + tampering coverage). Production paths never call this.
Future<Uint8List> encodeInkx({
  required String bookId,
  required String title,
  required String author,
  required String authorId,
  required List<Map<String, dynamic>> sections, // {id, title, section_index, content}
  required List<Map<String, dynamic>> images,   // {id, mime, blurhash, data: List<int>}
  required Map<String, dynamic> licenseObj,     // includes server_signature
  required List<int> licenseSignature,          // 64 raw bytes
  required List<int> deviceKey,
  int embeddingVersion = 1,
}) async {
  if (licenseSignature.length != _ed25519SigLen) {
    throw InkxError('license_signature must be $_ed25519SigLen bytes');
  }
  final expectedB64 = base64.encode(licenseSignature);
  if (licenseObj['server_signature'] != expectedB64) {
    throw InkxError(
        'license_obj.server_signature does not match license_signature bytes');
  }
  if (licenseObj['book_id'] != bookId) {
    throw InkxError('license_obj.book_id does not match book_id');
  }

  final bookKey = await deriveBookKey(
    deviceKey: deviceKey,
    bookId: bookId,
    licenseSignature: licenseSignature,
  );

  final chunkBlobs = <Uint8List>[];
  final sectionMeta = <Map<String, dynamic>>[];
  for (final s in sections) {
    final pt = utf8.encode(jsonEncode({
      'id': s['id'],
      'title': s['title'],
      'section_index': s['section_index'],
      'content': s['content'],
    }));
    final blob = await _aesGcmEncrypt(bookKey, pt);
    chunkBlobs.add(blob);
    sectionMeta.add({
      'id': s['id'],
      'title': s['title'],
      'section_index': s['section_index'],
      'chunk_index': chunkBlobs.length - 1,
    });
  }

  final imageMeta = <Map<String, dynamic>>[];
  for (final im in images) {
    final blob = await _aesGcmEncrypt(bookKey, (im['data'] as List<int>));
    chunkBlobs.add(blob);
    imageMeta.add({
      'id': im['id'],
      'mime': im['mime'],
      'blurhash': im['blurhash'],
      'chunk_index': chunkBlobs.length - 1,
    });
  }

  final chunkTable = <Map<String, dynamic>>[];
  var rel = 0;
  for (final blob in chunkBlobs) {
    chunkTable.add({'offset': rel, 'length': blob.length});
    rel += blob.length;
  }

  final header = <String, dynamic>{
    'v': _version,
    'book_id': bookId,
    'title': title,
    'author': author,
    'author_id': authorId,
    'license': licenseObj,
    'sections': sectionMeta,
    'images': imageMeta,
    'chunks': chunkTable,
    'embedding_version': embeddingVersion,
  };
  final headerPt = utf8.encode(jsonEncode(header));
  final headerBlob = await _aesGcmEncrypt(bookKey, headerPt);

  final headerLen = ByteData(4)..setUint32(0, headerBlob.length, Endian.big);
  final prefix = <int>[
    ..._magic,
    _version,
    0, // flags
    ...licenseSignature,
    ...headerLen.buffer.asUint8List(),
    ...headerBlob,
  ];
  final body = <int>[...prefix];
  for (final blob in chunkBlobs) {
    body.addAll(blob);
  }
  final mac = await Hmac.sha256().calculateMac(body, secretKey: bookKey);
  return Uint8List.fromList([...body, ...mac.bytes]);
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

Future<Uint8List> _aesGcmDecrypt(SecretKey key, List<int> blob) async {
  if (blob.length < _nonceLen + _gcmTagLen) {
    throw InkxError('chunk too short');
  }
  final nonce = blob.sublist(0, _nonceLen);
  final body = blob.sublist(_nonceLen, blob.length - _gcmTagLen);
  final tag = blob.sublist(blob.length - _gcmTagLen);
  final algo = AesGcm.with256bits();
  try {
    final pt = await algo.decrypt(
      SecretBox(body, nonce: nonce, mac: Mac(tag)),
      secretKey: key,
    );
    return Uint8List.fromList(pt);
  } on SecretBoxAuthenticationError catch (_) {
    throw InkxError('chunk decryption failed (wrong key or tampered ciphertext)');
  }
}

Future<Uint8List> _aesGcmEncrypt(SecretKey key, List<int> plaintext) async {
  final algo = AesGcm.with256bits();
  final box = await algo.encrypt(plaintext, secretKey: key);
  return Uint8List.fromList([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}

Future<void> _verifyLicenseSignature({
  required Map<String, dynamic> licenseObj,
  required List<int> signatureBytes,
  required List<int> publicKey,
}) async {
  if (publicKey.length != 32) {
    throw InkxError('Ed25519 public key must be 32 bytes');
  }
  // Canonical JSON of the license payload WITHOUT server_signature, with
  // sorted keys + fixed separators. Mirrors `_canonicalise` in license.py.
  final body = Map<String, dynamic>.from(licenseObj)
    ..remove('server_signature');
  final canonical = utf8.encode(_canonicalJson(body));
  final algo = Ed25519();
  final pub = SimplePublicKey(publicKey, type: KeyPairType.ed25519);
  final sig = Signature(signatureBytes, publicKey: pub);
  final ok = await algo.verify(canonical, signature: sig);
  if (!ok) {
    throw InkxError('license signature is invalid');
  }
  final expiresAt = licenseObj['expires_at'];
  if (expiresAt is! int) {
    throw InkxError('license missing integer expires_at');
  }
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (expiresAt <= nowSec) {
    throw InkxError('license has expired');
  }
}

/// JSON encode with sorted keys + no whitespace — matches Python's
/// `json.dumps(..., sort_keys=True, separators=(',', ':'))`.
String _canonicalJson(dynamic value) {
  if (value == null) return 'null';
  if (value is bool) return value ? 'true' : 'false';
  if (value is num) {
    if (value is int) return value.toString();
    // Match Python's float repr where possible. License payloads only
    // contain ints today, so this branch is defensive.
    return value.toString();
  }
  if (value is String) return jsonEncode(value);
  if (value is List) {
    final parts = value.map(_canonicalJson).join(',');
    return '[$parts]';
  }
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    final parts = keys
        .map((k) => '${jsonEncode(k)}:${_canonicalJson(value[k])}')
        .join(',');
    return '{$parts}';
  }
  throw InkxError('canonical_json: unsupported type ${value.runtimeType}');
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Decode a canonical UUID string (with or without hyphens) to 16 raw bytes.
Uint8List _uuidStringToBytes(String s) {
  final hex = s.replaceAll('-', '');
  if (hex.length != 32) {
    throw InkxError('book_id is not a valid UUID: $s');
  }
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    final h = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (h == null) {
      throw InkxError('book_id contains non-hex character: $s');
    }
    bytes[i] = h;
  }
  return bytes;
}
