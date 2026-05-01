/// Provider façade over [OfflineLibrary] + [OfflineDownloader].
///
/// Lazy-inits the Hive metadata box and the on-disk store on first
/// touch. The public Ed25519 verification key is bundled via
/// `--dart-define=INKX_LICENSE_PUBLIC_KEY=<base64>` at build time;
/// without it the provider refuses to download (and surfaces a clear
/// state code rather than crashing).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/services/offline/offline_library.dart';
import 'package:inkspacex/services/storage_service.dart';
import 'package:path_provider/path_provider.dart';

const String _offlineMetaBox = 'offline_meta';

enum OfflineStatus { idle, initialising, ready, error }

enum BookDownloadState { idle, downloading, downloaded, failed }

class OfflineProvider extends ChangeNotifier {
  OfflineProvider({
    required StorageService storage,
    required ApiClient apiClient,
    String? licensePublicKeyB64,
  })  : _storage = storage,
        _apiClient = apiClient,
        _licensePublicKeyB64 = licensePublicKeyB64 ??
            const String.fromEnvironment(
              'INKX_LICENSE_PUBLIC_KEY',
              defaultValue: '',
            );

  final StorageService _storage;
  final ApiClient _apiClient;
  final String _licensePublicKeyB64;

  OfflineStatus _status = OfflineStatus.idle;
  String? _errorMessage;
  OfflineLibrary? _library;
  OfflineDownloader? _downloader;
  final Map<String, BookDownloadState> _states = {};

  OfflineStatus get status => _status;
  String? get errorMessage => _errorMessage;

  /// True when an operator has provisioned the public key and the
  /// device store is available.
  bool get isAvailable =>
      _licensePublicKeyB64.isNotEmpty && _status == OfflineStatus.ready;

  /// Surfaces why the offline button is disabled when not [isAvailable].
  String? get unavailableReason {
    if (kIsWeb) {
      return 'Offline downloads are not available on web.';
    }
    if (_licensePublicKeyB64.isEmpty) {
      return 'Offline downloads are not configured for this build.';
    }
    if (_status == OfflineStatus.error) {
      return _errorMessage ?? 'Offline storage failed to initialise.';
    }
    return null;
  }

  Future<void> ensureReady() async {
    if (kIsWeb) return;
    if (_status == OfflineStatus.ready) return;
    if (_status == OfflineStatus.initialising) return;
    _status = OfflineStatus.initialising;
    notifyListeners();
    try {
      final dir = await _resolveRoot();
      final metaBox = await _openMetaBox();
      _library = OfflineLibrary(rootDir: dir, metaBox: metaBox);
      if (_licensePublicKeyB64.isNotEmpty) {
        _downloader = OfflineDownloader(
          library: _library!,
          apiClient: _apiClient,
          storage: _storage,
          licensePublicKey: base64.decode(_licensePublicKeyB64),
        );
      }
      _status = OfflineStatus.ready;
      _errorMessage = null;
    } catch (e, st) {
      log.e('[offline] init failed', error: e, stackTrace: st);
      _status = OfflineStatus.error;
      _errorMessage = e.toString();
    }
    notifyListeners();
  }

  /// Tests inject a custom root + box without going through path_provider
  /// or the bundled public key.
  @visibleForTesting
  Future<void> initWithLibrary({
    required OfflineLibrary library,
    OfflineDownloader? downloader,
  }) async {
    _library = library;
    _downloader = downloader;
    _status = OfflineStatus.ready;
    notifyListeners();
  }

  Future<Directory> _resolveRoot() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}offline');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Box<dynamic>> _openMetaBox() async {
    if (Hive.isBoxOpen(_offlineMetaBox)) {
      return Hive.box(_offlineMetaBox);
    }
    return Hive.openBox(_offlineMetaBox);
  }

  // -- Public API ----------------------------------------------------

  bool hasOffline(String bookId) {
    return _library?.hasOffline(bookId) ?? false;
  }

  OfflineBookMeta? metaFor(String bookId) {
    return _library?.metaFor(bookId);
  }

  List<OfflineBookMeta> list() {
    return _library?.list() ?? const [];
  }

  int totalBytes() => _library?.totalBytes() ?? 0;

  BookDownloadState stateOf(String bookId) {
    if (_states.containsKey(bookId)) return _states[bookId]!;
    if (hasOffline(bookId)) return BookDownloadState.downloaded;
    return BookDownloadState.idle;
  }

  Future<bool> download(String bookId) async {
    await ensureReady();
    final downloader = _downloader;
    if (downloader == null) {
      _errorMessage =
          'Offline downloads are not available (missing public key).';
      notifyListeners();
      return false;
    }
    _states[bookId] = BookDownloadState.downloading;
    notifyListeners();
    try {
      await downloader.download(bookId: bookId);
      _states[bookId] = BookDownloadState.downloaded;
      _errorMessage = null;
      notifyListeners();
      return true;
    } catch (e, st) {
      log.e('[offline] download failed for $bookId', error: e, stackTrace: st);
      _states[bookId] = BookDownloadState.failed;
      _errorMessage = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<void> evict(String bookId) async {
    await _library?.evict(bookId);
    _states.remove(bookId);
    notifyListeners();
  }

  Future<void> evictAll() async {
    await _library?.evictAll();
    _states.clear();
    notifyListeners();
  }
}
