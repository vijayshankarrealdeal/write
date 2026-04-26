/// On-disk store coverage for [OfflineLibrary].
///
/// Round-trip exercises save → metaFor → list → open → evict against a
/// real Hive box on a tmp directory. The downloader (network plumbing)
/// lives in a separate class and isn't exercised here — that layer
/// needs an HTTP fixture, which arrives with the integration suite.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:inkspacex/services/offline/inkx_codec.dart';
import 'package:inkspacex/services/offline/offline_library.dart';

const _bookId = '11111111-2222-3333-4444-555555555555';
const _otherBookId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

String _canonical(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is num) return v.toString();
  if (v is String) return jsonEncode(v);
  if (v is List) return '[${v.map(_canonical).join(',')}]';
  if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonical(v[k])}').join(',')}}';
  }
  throw StateError('unsupported');
}

Future<({Uint8List blob, List<int> publicKey, int expiresAt})> _buildBlob({
  required List<int> deviceKey,
  String bookId = _bookId,
  int ttl = 3600,
}) async {
  final algo = Ed25519();
  final keyPair = await algo.newKeyPair();
  final pub = (await keyPair.extractPublicKey()).bytes;

  final issuedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final body = <String, dynamic>{
    'user_id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    'device_id': 'a1a1a1a1-b2b2-c3c3-d4d4-e5e5e5e5e5e5',
    'book_id': bookId,
    'issued_at': issuedAt,
    'expires_at': issuedAt + ttl,
  };
  final sig = await algo.sign(utf8.encode(_canonical(body)), keyPair: keyPair);
  final licenseObj = <String, dynamic>{
    ...body,
    'server_signature': base64.encode(sig.bytes),
  };
  final blob = await encodeInkx(
    bookId: bookId,
    title: 'A Title',
    author: 'An Author',
    authorId: '99999999-8888-7777-6666-555555555555',
    sections: const [
      {
        'id': 's0',
        'title': 'Only',
        'section_index': 0,
        'content': 'inline',
      }
    ],
    images: const [],
    licenseObj: licenseObj,
    licenseSignature: sig.bytes,
    deviceKey: deviceKey,
  );
  return (blob: blob, publicKey: pub, expiresAt: body['expires_at'] as int);
}

void main() {
  late Directory tmpRoot;
  late Directory hiveDir;
  late Box<dynamic> metaBox;
  late OfflineLibrary lib;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('inkx_offline_test_');
    hiveDir = await Directory.systemTemp.createTemp('inkx_offline_hive_');
    Hive.init(hiveDir.path);
    // Always open a fresh, uniquely named box so cross-test state never
    // leaks via Hive's process-wide registry.
    final boxName = 'meta_${DateTime.now().microsecondsSinceEpoch}';
    metaBox = await Hive.openBox(boxName);
    lib = OfflineLibrary(rootDir: tmpRoot, metaBox: metaBox);
  });

  tearDown(() async {
    await metaBox.close();
    try {
      await tmpRoot.delete(recursive: true);
    } catch (_) {}
    try {
      await hiveDir.delete(recursive: true);
    } catch (_) {}
  });

  test('deviceKey is stable across calls', () async {
    final a = await lib.deviceKey();
    final b = await lib.deviceKey();
    expect(a, b);
    expect(a, hasLength(32));
  });

  test('deviceId is stable across calls', () async {
    final a = await lib.deviceId();
    final b = await lib.deviceId();
    expect(a, b);
    expect(a, hasLength(36)); // canonical UUID
  });

  test('save → metaFor + list + hasOffline round-trip', () async {
    final dk = await lib.deviceKey();
    final built = await _buildBlob(deviceKey: dk);
    final meta = await lib.save(
      bookId: _bookId,
      blob: built.blob,
      title: 'A Title',
      author: 'An Author',
      licenseExpiresAt: built.expiresAt,
    );
    expect(meta.bookId, _bookId);
    expect(meta.sizeBytes, built.blob.length);
    expect(lib.hasOffline(_bookId), isTrue);
    expect(lib.metaFor(_bookId)?.title, 'A Title');
    expect(lib.list().map((m) => m.bookId), [_bookId]);
    expect(lib.totalBytes(), built.blob.length);
  });

  test('open decrypts a stored book through the codec', () async {
    final dk = await lib.deviceKey();
    final built = await _buildBlob(deviceKey: dk);
    await lib.save(
      bookId: _bookId,
      blob: built.blob,
      title: 'A Title',
      author: 'An Author',
      licenseExpiresAt: built.expiresAt,
    );
    final book = await lib.open(
      bookId: _bookId,
      licensePublicKey: built.publicKey,
    );
    expect(book.title, 'A Title');
    expect(book.sections, hasLength(1));
    final s0 = await book.readSection(0);
    expect(s0['content'], 'inline');
  });

  test('list orders by downloadedAt desc', () async {
    final dk = await lib.deviceKey();
    final a = await _buildBlob(deviceKey: dk, bookId: _bookId);
    await lib.save(
      bookId: _bookId,
      blob: a.blob,
      title: 'first',
      author: 'x',
      licenseExpiresAt: a.expiresAt,
    );
    // Wait one second so downloadedAt strictly increases.
    await Future<void>.delayed(const Duration(seconds: 1));
    final b = await _buildBlob(deviceKey: dk, bookId: _otherBookId);
    await lib.save(
      bookId: _otherBookId,
      blob: b.blob,
      title: 'second',
      author: 'x',
      licenseExpiresAt: b.expiresAt,
    );
    expect(lib.list().map((m) => m.bookId), [_otherBookId, _bookId]);
  });

  test('evict removes file + metadata', () async {
    final dk = await lib.deviceKey();
    final built = await _buildBlob(deviceKey: dk);
    await lib.save(
      bookId: _bookId,
      blob: built.blob,
      title: 'A Title',
      author: 'An Author',
      licenseExpiresAt: built.expiresAt,
    );
    final path = lib.metaFor(_bookId)!.filePath;
    expect(File(path).existsSync(), isTrue);
    await lib.evict(_bookId);
    expect(lib.hasOffline(_bookId), isFalse);
    expect(lib.metaFor(_bookId), isNull);
    expect(File(path).existsSync(), isFalse);
  });

  test('open after evict throws StateError', () async {
    final dk = await lib.deviceKey();
    final built = await _buildBlob(deviceKey: dk);
    await lib.save(
      bookId: _bookId,
      blob: built.blob,
      title: 't',
      author: 'a',
      licenseExpiresAt: built.expiresAt,
    );
    await lib.evict(_bookId);
    expect(
      () => lib.open(
        bookId: _bookId,
        licensePublicKey: built.publicKey,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('evictAll clears every book and rotates the device key', () async {
    final dk1 = await lib.deviceKey();
    final built = await _buildBlob(deviceKey: dk1);
    await lib.save(
      bookId: _bookId,
      blob: built.blob,
      title: 't',
      author: 'a',
      licenseExpiresAt: built.expiresAt,
    );
    await lib.evictAll();
    expect(lib.list(), isEmpty);
    final dk2 = await lib.deviceKey();
    // A fresh device_key is generated on next request — old `.inkx`
    // bytes (already deleted, but conceptually) wouldn't decrypt
    // because the HKDF input differs.
    expect(dk2, isNot(equals(dk1)));
  });

  test('isExpired flips once expiry passes', () async {
    final dk = await lib.deviceKey();
    final built = await _buildBlob(deviceKey: dk, ttl: -10);
    await lib.save(
      bookId: _bookId,
      blob: built.blob,
      title: 't',
      author: 'a',
      licenseExpiresAt: built.expiresAt,
    );
    expect(lib.metaFor(_bookId)!.isExpired, isTrue);
    expect(lib.metaFor(_bookId)!.needsRenewal, isTrue);
  });
}
