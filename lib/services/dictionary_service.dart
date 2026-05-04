import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/api/api_realtime_service.dart';
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/services/storage_service.dart';

/// On-device global dictionary cache, fully server-sourced.
///
/// Architecture:
///
/// 1. **Cold start** — cache lives in Hive. On first launch the cache
///    is empty and the version is 0; the first snapshot fetch returns
///    every word currently in the global dictionary as a single delta
///    and persists them to Hive. No words are bundled with the app.
/// 2. **Delta sync** — on every app start (and again every time the
///    SSE `dictionary` channel pings) we GET
///    `/api/dictionary/snapshot?since=<cached_version>`. The backend
///    responds with `{version, added: [...], removed: [...]}`. Empty
///    arrays when nothing has changed — a cheap up-to-date check.
/// 3. **Submit on add** — when the user taps "Add to dictionary" we
///    POST `/api/dictionary/submit`. The word is queued for an admin
///    AI-merge pass; it never silently joins the global dict.
///
/// The wire payload of a snapshot fetch is one integer out (`since`),
/// a delta back. No prose, no per-word user identity.
class DictionaryService extends ChangeNotifier {
  /// [language] defaults to the platform locale (falling back to `en`).
  /// Backend snapshots, submissions, and the on-device cache are all
  /// scoped to this language code so a future spanish/hindi rollout
  /// doesn't conflate vocabularies.
  DictionaryService(this._api, this._storage, {String? language})
      : _language = (language ?? _detectPlatformLanguage()).toLowerCase();

  final ApiClient _api;
  final StorageService _storage;

  final String _language;

  /// ISO-639-1 code for the dictionary this service is bound to.
  String get language => _language;

  static String _detectPlatformLanguage() {
    // PlatformDispatcher works without a Widget context — DictionaryService
    // is constructed at provider time, before any MaterialApp is on screen.
    final code = PlatformDispatcher.instance.locale.languageCode.trim();
    return code.isEmpty ? 'en' : code;
  }

  Set<String> _words = <String>{};
  int _version = 0;
  StreamSubscription<Map<String, dynamic>>? _sseSub;

  /// Read-only snapshot of the merged dictionary. Rebuilt on every
  /// mutation so the returned reference is safe to iterate without
  /// copying.
  Set<String> get words => _words;
  int get version => _version;

  /// Load cached state from Hive. Cheap to call repeatedly. The first
  /// `refresh()` after `init()` will pull the full dictionary if Hive
  /// was empty.
  Future<void> init() async {
    _version = _storage.getGlobalDictionaryVersion(language: _language);
    _words = _storage.getGlobalDictionaryWords(language: _language);
    notifyListeners();
  }

  /// Pull the delta since the cached version and apply it. Safe to call
  /// from multiple call sites (app start, SSE bump, manual refresh) —
  /// concurrent fetches collapse via the in-flight future.
  Future<void> refresh() {
    return _refreshFuture ??= _refreshOnce()
        .whenComplete(() => _refreshFuture = null);
  }

  Future<void>? _refreshFuture;

  Future<void> _refreshOnce() async {
    try {
      final res = await _api.get(
        '/api/dictionary/snapshot',
        queryParams: {'since': _version, 'language': _language},
      );
      final data = res.data;
      if (data is! Map) return;
      final serverVersion = (data['version'] as num?)?.toInt() ?? _version;
      final added = (data['added'] as List?)?.whereType<String>().toList()
          ?? const [];
      final removed = (data['removed'] as List?)?.whereType<String>().toList()
          ?? const [];

      if (serverVersion == _version && added.isEmpty && removed.isEmpty) {
        return;
      }

      final next = <String>{..._words};
      next.addAll(added.map((w) => w.toLowerCase()));
      for (final w in removed) {
        next.remove(w.toLowerCase());
      }
      _words = next;
      _version = serverVersion;
      await _storage.saveGlobalDictionaryWords(_words, language: _language);
      await _storage.saveGlobalDictionaryVersion(_version, language: _language);
      log.i(
        '[dict/$_language] applied delta: +${added.length} -${removed.length} '
        '→ v$_version (${_words.length} words)',
      );
      notifyListeners();
    } on ApiException catch (e) {
      log.w('[dict/$_language] snapshot failed: ${e.message}');
    } catch (e) {
      log.w('[dict/$_language] snapshot error: $e');
    }
  }

  /// Subscribe to the global `dictionary` SSE channel. Each
  /// `dictionary.updated` ping triggers a delta refresh — no payload
  /// inspection needed beyond "something changed".
  ///
  /// Idempotent and re-attachable: a second call swaps the underlying
  /// subscription so re-auth (which spawns a fresh realtime service)
  /// gets a working stream.
  void attachRealtime(ApiRealtimeService realtime) {
    _sseSub?.cancel();
    _sseSub = realtime.dictionaryChannel().listen(
      (_) {
        unawaited(refresh());
      },
      onError: (e) => log.w('[dict] sse error: $e'),
    );
  }

  /// Queue a word for the next admin merge. Best-effort — a failed
  /// submit is logged but not surfaced to the user, so an offline tap
  /// of "Add to dictionary" still works locally. Uses the service's
  /// configured [language] so submissions land in the right per-locale
  /// bucket on the backend.
  Future<void> submitWord(String word, {String? language}) async {
    final cleaned = word.trim().toLowerCase();
    if (cleaned.length < 2) return;
    try {
      await _api.post(
        '/api/dictionary/submit',
        data: {'word': cleaned, 'language': language ?? _language},
        silent: true,
      );
    } on ApiException catch (e) {
      log.w('[dict/$_language] submit failed for "$cleaned": ${e.message}');
    } catch (e) {
      log.w('[dict/$_language] submit error for "$cleaned": $e');
    }
  }

  @override
  void dispose() {
    _sseSub?.cancel();
    super.dispose();
  }
}
