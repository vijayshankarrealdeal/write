/// On-disk store for downloaded `.inkx` books + their metadata.
///
/// Layout:
///
///   <appSupport>/offline/<book_id>.inkx     // encrypted blob
///
/// Metadata (per-book license expiry, title, downloaded-at) lives in
/// the Hive box `offline_meta`. The same box also holds a single
/// `device_key` entry — a 32-byte buffer generated once on first use
/// and reused for every download. The device_key is one of the two
/// inputs to the per-book HKDF, so wiping it (via [evictAll]) makes
/// every existing `.inkx` undecryptable.
///
/// Network operations (license + package fetch) live in
/// [OfflineDownloader] so the on-disk store stays a pure I/O concern
/// and can be unit-tested without a server.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/services/offline/inkx_codec.dart';
import 'package:inkspacex/services/storage_service.dart';
import 'package:uuid/uuid.dart';

const String _deviceKeyKey = '__device_key';
const String _bookKeyPrefix = 'book::';

class OfflineBookMeta {
  OfflineBookMeta({
    required this.bookId,
    required this.title,
    required this.author,
    required this.filePath,
    required this.sizeBytes,
    required this.licenseExpiresAt,
    required this.downloadedAt,
  });

  factory OfflineBookMeta.fromJson(Map json) => OfflineBookMeta(
        bookId: json['book_id'] as String,
        title: json['title'] as String? ?? '',
        author: json['author'] as String? ?? '',
        filePath: json['file_path'] as String,
        sizeBytes: json['size_bytes'] as int? ?? 0,
        licenseExpiresAt: json['license_expires_at'] as int? ?? 0,
        downloadedAt: json['downloaded_at'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'book_id': bookId,
        'title': title,
        'author': author,
        'file_path': filePath,
        'size_bytes': sizeBytes,
        'license_expires_at': licenseExpiresAt,
        'downloaded_at': downloadedAt,
      };

  final String bookId;
  final String title;
  final String author;
  final String filePath;
  final int sizeBytes;
  final int licenseExpiresAt; // unix seconds
  final int downloadedAt;     // unix seconds

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 >= licenseExpiresAt;

  /// Renew within 7 days of expiry, per p2.md §4.1.
  bool get needsRenewal {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return licenseExpiresAt - nowSec <= 7 * 24 * 60 * 60;
  }
}

/// Pure on-disk + metadata library. Network plumbing is separate so
/// unit tests can drop in a fake [OfflineDownloader].
class OfflineLibrary {
  OfflineLibrary({
    required Directory rootDir,
    required Box<dynamic> metaBox,
  })  : _rootDir = rootDir,
        _metaBox = metaBox;

  final Directory _rootDir;
  final Box<dynamic> _metaBox;

  /// 32-byte device key, generated once and persisted. Used as one of
  /// the two HKDF inputs for every book. Wiping this (see [evictAll])
  /// makes every existing `.inkx` undecryptable.
  Future<List<int>> deviceKey() async {
    final raw = _metaBox.get(_deviceKeyKey);
    if (raw is List && raw.length == 32) {
      return List<int>.from(raw.cast<int>());
    }
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    await _metaBox.put(_deviceKeyKey, bytes);
    return bytes;
  }

  /// Stable per-install device id (uuid v4). Sent to the server with
  /// every license request so a license can be invalidated on logout.
  Future<String> deviceId() async {
    final existing = _metaBox.get('__device_id');
    if (existing is String && existing.isNotEmpty) return existing;
    final id = const Uuid().v4();
    await _metaBox.put('__device_id', id);
    return id;
  }

  /// Path the encrypted blob for [bookId] would live at, regardless of
  /// whether it's actually downloaded.
  File _fileFor(String bookId) =>
      File('${_rootDir.path}${Platform.pathSeparator}$bookId.inkx');

  Future<void> _ensureRoot() async {
    if (!await _rootDir.exists()) {
      await _rootDir.create(recursive: true);
    }
  }

  bool hasOffline(String bookId) {
    final raw = _metaBox.get('$_bookKeyPrefix$bookId');
    if (raw is! Map) return false;
    return _fileFor(bookId).existsSync();
  }

  OfflineBookMeta? metaFor(String bookId) {
    final raw = _metaBox.get('$_bookKeyPrefix$bookId');
    if (raw is! Map) return null;
    return OfflineBookMeta.fromJson(raw);
  }

  List<OfflineBookMeta> list() {
    final out = <OfflineBookMeta>[];
    for (final key in _metaBox.keys) {
      if (key is String && key.startsWith(_bookKeyPrefix)) {
        final raw = _metaBox.get(key);
        if (raw is Map) {
          out.add(OfflineBookMeta.fromJson(raw));
        }
      }
    }
    out.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    return out;
  }

  /// Total bytes the offline store occupies on disk.
  int totalBytes() {
    var n = 0;
    for (final m in list()) {
      n += m.sizeBytes;
    }
    return n;
  }

  /// Persist a freshly fetched blob. The caller should already have
  /// verified it decodes (see [OfflineDownloader.download]).
  Future<OfflineBookMeta> save({
    required String bookId,
    required Uint8List blob,
    required String title,
    required String author,
    required int licenseExpiresAt,
  }) async {
    await _ensureRoot();
    final file = _fileFor(bookId);
    await file.writeAsBytes(blob, flush: true);
    final meta = OfflineBookMeta(
      bookId: bookId,
      title: title,
      author: author,
      filePath: file.path,
      sizeBytes: blob.length,
      licenseExpiresAt: licenseExpiresAt,
      downloadedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await _metaBox.put('$_bookKeyPrefix$bookId', meta.toJson());
    return meta;
  }

  /// Decode the stored blob and return a handle. Throws [InkxError] on
  /// any tampering; throws [StateError] if the book isn't downloaded.
  Future<InkxBook> open({
    required String bookId,
    required List<int> licensePublicKey,
  }) async {
    final meta = metaFor(bookId);
    if (meta == null) {
      throw StateError('book $bookId is not downloaded');
    }
    final file = File(meta.filePath);
    if (!await file.exists()) {
      throw StateError('offline file missing for $bookId at ${meta.filePath}');
    }
    final bytes = await file.readAsBytes();
    final dk = await deviceKey();
    return decodeInkx(
      bytes,
      deviceKey: dk,
      expectedBookId: bookId,
      licensePublicKey: licensePublicKey,
    );
  }

  Future<void> evict(String bookId) async {
    final meta = metaFor(bookId);
    if (meta != null) {
      try {
        final f = File(meta.filePath);
        if (await f.exists()) await f.delete();
      } catch (e) {
        log.w('[offline] failed to delete ${meta.filePath}: $e');
      }
    }
    await _metaBox.delete('$_bookKeyPrefix$bookId');
  }

  /// Wipe every offline book + the device key. Existing `.inkx` files
  /// outside the app sandbox (there shouldn't be any) become unreadable
  /// because the HKDF input is gone.
  Future<void> evictAll() async {
    for (final meta in list()) {
      await evict(meta.bookId);
    }
    await _metaBox.delete(_deviceKeyKey);
    await _metaBox.delete('__device_id');
  }
}

/// Network plumbing: hits `/api/offline/license` and
/// `/api/offline/package/{book_id}`, validates the returned blob, and
/// writes it through [OfflineLibrary.save].
class OfflineDownloader {
  OfflineDownloader({
    required this.library,
    required this.apiClient,
    required this.storage,
    required this.licensePublicKey,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final OfflineLibrary library;
  final ApiClient apiClient;
  final StorageService storage;

  /// Bundled at app build via `--dart-define=INKX_LICENSE_PUBLIC_KEY=...`.
  /// Must be the base64 form of the 32-byte raw Ed25519 public key whose
  /// matching private seed lives on the server in `INKX_LICENSE_SIGNING_KEY`.
  final List<int> licensePublicKey;

  final http.Client _http;

  /// End-to-end download. Returns metadata for the freshly stored book.
  /// Throws on auth, license, network, or decode failures — the on-disk
  /// store is only updated after a successful local decode.
  Future<OfflineBookMeta> download({required String bookId}) async {
    final deviceId = await library.deviceId();
    final deviceKey = await library.deviceKey();

    // 1. Issue the license.
    final licenseResp = await apiClient.post(
      '/api/offline/license',
      data: {'book_id': bookId, 'device_id': deviceId},
    );
    if (licenseResp.data is! Map) {
      throw StateError('Unexpected license response shape');
    }
    final licenseObj = Map<String, dynamic>.from(licenseResp.data as Map);
    final expiresAt = licenseObj['expires_at'] as int? ?? 0;

    // 2. Fetch the package (binary). The /api/offline/package endpoint
    // returns application/octet-stream so we cannot reuse ApiClient's
    // JSON-shaped response — go direct over the raw http client and
    // hand-roll auth/refresh-aware behaviour minimally.
    final url = Uri.parse('${ApiClient.baseUrl}/api/offline/package/$bookId');
    final token = storage.getAuthToken();
    final body = jsonEncode({
      'license': licenseObj,
      'device_key_b64': base64.encode(deviceKey),
    });
    final resp = await _http
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            if (token != null && token.isNotEmpty)
              'Authorization': 'Bearer $token',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 60));

    if (resp.statusCode != 200) {
      throw StateError(
          'package download failed: HTTP ${resp.statusCode} ${resp.body}');
    }
    final blob = resp.bodyBytes;

    // 3. Decode locally before writing — proves the bytes are intact
    // and the keys agree before we commit anything to disk.
    final book = await decodeInkx(
      blob,
      deviceKey: deviceKey,
      expectedBookId: bookId,
      licensePublicKey: licensePublicKey,
    );

    return library.save(
      bookId: bookId,
      blob: blob,
      title: book.title,
      author: book.author,
      licenseExpiresAt: expiresAt,
    );
  }

  /// Re-acquire a license without redownloading the bytes — used when
  /// [OfflineBookMeta.needsRenewal] is true. Today this just calls
  /// [download] (the server packages a fresh copy) because the existing
  /// blob would still need a fresh license to decode if expiry has
  /// already passed; long-term we can add a `/api/offline/relicense`
  /// that returns just the license envelope.
  Future<OfflineBookMeta> renew({required String bookId}) =>
      download(bookId: bookId);
}
