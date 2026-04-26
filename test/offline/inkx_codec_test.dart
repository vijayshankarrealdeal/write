/// `.inkx` codec round-trip + tampering coverage.
///
/// These tests exercise the Dart codec end-to-end against a freshly
/// generated Ed25519 key pair (no native deps). They mirror the
/// server-side `backend/tests/test_offline_codec.py` cases so that the
/// two sides stay in lockstep — the format is the contract.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/services/offline/inkx_codec.dart';

const _bookId = '11111111-2222-3333-4444-555555555555';
const _authorId = '99999999-8888-7777-6666-555555555555';
const _userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const _deviceId = 'a1a1a1a1-b2b2-c3c3-d4d4-e5e5e5e5e5e5';

class _Fixture {
  _Fixture({
    required this.deviceKey,
    required this.licenseObj,
    required this.licenseSig,
    required this.publicKey,
    required this.bytes,
  });

  final List<int> deviceKey;
  final Map<String, dynamic> licenseObj;
  final List<int> licenseSig;
  final List<int> publicKey;
  final Uint8List bytes;
}

String _canonicalJson(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is num) return v is int ? v.toString() : v.toString();
  if (v is String) return jsonEncode(v);
  if (v is List) return '[${v.map(_canonicalJson).join(',')}]';
  if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonicalJson(v[k])}').join(',')}}';
  }
  throw StateError('unsupported');
}

Future<_Fixture> _build({
  int ttlSeconds = 3600,
  List<Map<String, dynamic>>? sections,
  List<Map<String, dynamic>>? images,
  String bookId = _bookId,
}) async {
  final algo = Ed25519();
  final keyPair = await algo.newKeyPair();
  final publicBytes = (await keyPair.extractPublicKey()).bytes;

  final issuedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final body = <String, dynamic>{
    'user_id': _userId,
    'device_id': _deviceId,
    'book_id': bookId,
    'issued_at': issuedAt,
    'expires_at': issuedAt + ttlSeconds,
  };
  final canonical = utf8.encode(_canonicalJson(body));
  final sig = await algo.sign(canonical, keyPair: keyPair);
  final licenseObj = <String, dynamic>{
    ...body,
    'server_signature': base64.encode(sig.bytes),
  };

  final deviceKey = List<int>.generate(32, (i) => (i * 7 + 3) & 0xff);

  final blob = await encodeInkx(
    bookId: bookId,
    title: 'A Title',
    author: 'An Author',
    authorId: _authorId,
    sections: sections ??
        const [
          {
            'id': 's1',
            'title': 'Chapter 1',
            'section_index': 0,
            'content': {'ops': [{'insert': 'hello\n'}]},
          },
          {
            'id': 's2',
            'title': 'Chapter 2',
            'section_index': 1,
            'content': {'ops': [{'insert': 'world\n'}]},
          },
        ],
    images: images ?? const [],
    licenseObj: licenseObj,
    licenseSignature: sig.bytes,
    deviceKey: deviceKey,
  );

  return _Fixture(
    deviceKey: deviceKey,
    licenseObj: licenseObj,
    licenseSig: sig.bytes,
    publicKey: publicBytes,
    bytes: blob,
  );
}

void main() {
  group('inkx codec', () {
    test('round-trip: encode → decode preserves sections', () async {
      final f = await _build();
      final book = await decodeInkx(
        f.bytes,
        deviceKey: f.deviceKey,
        expectedBookId: _bookId,
        licensePublicKey: f.publicKey,
      );
      expect(book.bookId, _bookId);
      expect(book.title, 'A Title');
      expect(book.author, 'An Author');
      expect(book.sections, hasLength(2));
      expect(book.sections[0].title, 'Chapter 1');
      expect(book.sections[1].sectionIndex, 1);
      final s0 = await book.readSection(0);
      expect(s0['content'], {
        'ops': [{'insert': 'hello\n'}],
      });
      final s1 = await book.readSection(1);
      expect(s1['title'], 'Chapter 2');
    });

    test('round-trip: image bytes survive', () async {
      final imgBytes = List<int>.generate(64, (i) => i & 0xff);
      final f = await _build(
        sections: const [
          {
            'id': 's1',
            'title': 'Only',
            'section_index': 0,
            'content': 'inline',
          },
        ],
        images: [
          {
            'id': 'i1',
            'mime': 'image/png',
            'blurhash': 'L9AB',
            'data': imgBytes,
          },
        ],
      );
      final book = await decodeInkx(
        f.bytes,
        deviceKey: f.deviceKey,
        expectedBookId: _bookId,
        licensePublicKey: f.publicKey,
      );
      expect(book.images, hasLength(1));
      expect(book.images.first.mime, 'image/png');
      final got = await book.readImage('i1');
      expect(got, imgBytes);
    });

    test('wrong device key trips HMAC before any decryption', () async {
      final f = await _build();
      final wrong = List<int>.generate(32, (i) => 42);
      expect(
        () => decodeInkx(
          f.bytes,
          deviceKey: wrong,
          expectedBookId: _bookId,
          licensePublicKey: f.publicKey,
        ),
        throwsA(isA<InkxError>().having(
          (e) => e.message,
          'message',
          contains('HMAC'),
        )),
      );
    });

    test('wrong expected_book_id trips HMAC (book_id is part of HKDF)',
        () async {
      final f = await _build();
      const otherUuid = '00000000-0000-0000-0000-000000000000';
      expect(
        () => decodeInkx(
          f.bytes,
          deviceKey: f.deviceKey,
          expectedBookId: otherUuid,
          licensePublicKey: f.publicKey,
        ),
        throwsA(isA<InkxError>()),
      );
    });

    test('corrupt magic byte is rejected before any crypto', () async {
      final f = await _build();
      final tampered = Uint8List.fromList(f.bytes);
      tampered[0] = 0x00;
      expect(
        () => decodeInkx(
          tampered,
          deviceKey: f.deviceKey,
          expectedBookId: _bookId,
          licensePublicKey: f.publicKey,
        ),
        throwsA(isA<InkxError>().having(
          (e) => e.message,
          'message',
          contains('magic'),
        )),
      );
    });

    test('flipped HMAC trailer byte is rejected', () async {
      final f = await _build();
      final tampered = Uint8List.fromList(f.bytes);
      tampered[tampered.length - 1] ^= 0x01;
      expect(
        () => decodeInkx(
          tampered,
          deviceKey: f.deviceKey,
          expectedBookId: _bookId,
          licensePublicKey: f.publicKey,
        ),
        throwsA(isA<InkxError>().having(
          (e) => e.message,
          'message',
          contains('HMAC'),
        )),
      );
    });

    test('expired license is rejected after decrypt', () async {
      final f = await _build(ttlSeconds: -1); // already expired
      expect(
        () => decodeInkx(
          f.bytes,
          deviceKey: f.deviceKey,
          expectedBookId: _bookId,
          licensePublicKey: f.publicKey,
        ),
        throwsA(isA<InkxError>().having(
          (e) => e.message,
          'message',
          contains('expired'),
        )),
      );
    });

    test('wrong public key fails license verification', () async {
      final f = await _build();
      final algo = Ed25519();
      final wrongKey = await algo.newKeyPair();
      final wrongPub = (await wrongKey.extractPublicKey()).bytes;
      expect(
        () => decodeInkx(
          f.bytes,
          deviceKey: f.deviceKey,
          expectedBookId: _bookId,
          licensePublicKey: wrongPub,
        ),
        throwsA(isA<InkxError>().having(
          (e) => e.message,
          'message',
          contains('signature'),
        )),
      );
    });

    test('section decrypt is lazy (out-of-range section throws cleanly)',
        () async {
      final f = await _build();
      final book = await decodeInkx(
        f.bytes,
        deviceKey: f.deviceKey,
        expectedBookId: _bookId,
        licensePublicKey: f.publicKey,
      );
      expect(
        () => book.readSection(99),
        throwsA(isA<InkxError>()),
      );
    });

    test('encode rejects mismatched server_signature on license_obj', () async {
      final f = await _build();
      final fakeLicense = Map<String, dynamic>.from(f.licenseObj);
      fakeLicense['server_signature'] = base64.encode(List.filled(64, 0));
      expect(
        () => encodeInkx(
          bookId: _bookId,
          title: 't',
          author: 'a',
          authorId: _authorId,
          sections: const [
            {
              'id': 's1',
              'title': 'x',
              'section_index': 0,
              'content': 'x',
            }
          ],
          images: const [],
          licenseObj: fakeLicense,
          licenseSignature: f.licenseSig,
          deviceKey: f.deviceKey,
        ),
        throwsA(isA<InkxError>()),
      );
    });
  });
}
