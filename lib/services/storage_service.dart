import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/app_log.dart';

class StorageService {
  static const String _boxName = 'writer_app_box';
  // Keychain (iOS/macOS) / EncryptedSharedPreferences (Android) / AES on web.
  // Used only for email/password creds — JWTs stay in Hive since they're
  // short-lived and getting them per request needs to be sync.
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  static const String _secureKeyEmail = 'auth_email_v1';
  static const String _secureKeyPassword = 'auth_password_v1';
  // Legacy un-namespaced keys, deleted once on first run after the
  // per-user-sandbox change. Listed here so the migration is in one place.
  static const String _legacyKeyBooks = 'user_books_json';
  static const String _legacyKeyRecentSearches = 'recent_searches';
  static const String _legacyOutboxBoxName = 'sync_outbox';
  static const String _keyTheme = 'app_theme_mode';
  static const String _keyOnboarding = 'onboarding_complete';
  static const String _keyAuthToken = 'auth_token';
  static const String _keyRefreshToken = 'refresh_token';
  static const String _keyOnboardingPrefs = 'onboarding_preferences';
  static const String _keySectionsViewMode = 'sections_view_mode';
  static const String _keyMigrationDoneV1 = 'migration_user_sandbox_v1';
  static const int _recentSearchesMax = 8;

  late Box _box;
  String? _currentUid;

  Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox(_boxName);
    await _runUserSandboxMigration();
  }

  /// One-shot deletion of pre-sandbox data. The shipped contract changed
  /// (books and outbox went per-user), so the old un-namespaced keys are
  /// no longer reachable through any code path — wiping them avoids dead
  /// disk usage.
  Future<void> _runUserSandboxMigration() async {
    if (_box.get(_keyMigrationDoneV1) == true) return;
    await _box.delete(_legacyKeyBooks);
    await _box.delete(_legacyKeyRecentSearches);
    if (await Hive.boxExists(_legacyOutboxBoxName)) {
      await Hive.deleteBoxFromDisk(_legacyOutboxBoxName);
    }
    await _box.put(_keyMigrationDoneV1, true);
  }

  /// Set the current user's sandbox. All per-user reads/writes (books,
  /// recent searches) are scoped under this uid. Pass `null` on logout —
  /// reads return empty and writes throw.
  void setUserScope(String? uid) {
    _currentUid = uid;
  }

  String _userKey(String prefix) {
    final uid = _currentUid;
    if (uid == null) {
      throw StateError(
        'StorageService has no user scope. Call setUserScope(uid) after '
        'auth resolves before reading/writing per-user data.',
      );
    }
    return '${prefix}__$uid';
  }

  String? _userKeyOrNull(String prefix) {
    final uid = _currentUid;
    if (uid == null) return null;
    return '${prefix}__$uid';
  }

  // --- Books Storage ---

  List<WritingModel> getBooks() {
    final key = _userKeyOrNull('user_books_json');
    if (key == null) return const [];
    final rawList = _box.get(key, defaultValue: <String>[]);
    if (rawList is List) {
      try {
        return rawList
            .map((e) {
              if (e is String) {
                final Map<String, dynamic> jsonMap = jsonDecode(e);
                return WritingModel.fromJson(jsonMap);
              }
              return null; // Should not happen
            })
            .whereType<WritingModel>()
            .toList();
      } catch (e) {
        debugPrint("Error parsing books: $e");
        return [];
      }
    }
    return [];
  }

  Future<void> saveBooks(List<WritingModel> books) async {
    final List<String> encodedList = books
        .map((book) => jsonEncode(book.toJson()))
        .toList();
    await _box.put(_userKey('user_books_json'), encodedList);
  }

  Future<void> clearBooks() async {
    final key = _userKeyOrNull('user_books_json');
    if (key == null) return;
    await _box.delete(key);
  }

  // --- Settings Storage ---

  String getThemeMode() {
    return _box.get(_keyTheme, defaultValue: 'system');
  }

  Future<void> saveThemeMode(String mode) async {
    await _box.put(_keyTheme, mode);
  }

  String getSectionsViewMode() {
    return _box.get(_keySectionsViewMode, defaultValue: 'grid');
  }

  Future<void> saveSectionsViewMode(String mode) async {
    await _box.put(_keySectionsViewMode, mode);
  }

  // --- Onboarding & Auth ---

  bool isOnboardingComplete() {
    return _box.get(_keyOnboarding, defaultValue: false);
  }

  Future<void> completeOnboarding() async {
    await _box.put(_keyOnboarding, true);
  }

  Future<void> saveOnboardingPreferences(Map<String, dynamic> prefs) async {
    await _box.put(_keyOnboardingPrefs, jsonEncode(prefs));
  }

  Map<String, dynamic>? getOnboardingPreferences() {
    final raw = _box.get(_keyOnboardingPrefs);
    if (raw is String) {
      try {
        return jsonDecode(raw);
      } catch (_) {}
    }
    return null;
  }

  Future<void> clearOnboardingPreferences() async {
    await _box.delete(_keyOnboardingPrefs);
  }

  String? getAuthToken() {
    return _box.get(_keyAuthToken);
  }

  Future<void> saveAuthToken(String token) async {
    await _box.put(_keyAuthToken, token);
  }

  String? getRefreshToken() {
    return _box.get(_keyRefreshToken);
  }

  Future<void> saveRefreshToken(String token) async {
    await _box.put(_keyRefreshToken, token);
  }

  Future<void> clearAuth() async {
    await _box.delete(_keyAuthToken);
    await _box.delete(_keyRefreshToken);
    await _box.delete('user_profile');
  }

  /// Stash the user's email/password so a session that lost both access and
  /// refresh tokens (long offline / server-rotated keys / etc) can recover
  /// without dumping the user back on the login screen. Only called on
  /// successful email/password auth — Google sign-in users never hit this.
  Future<void> saveCredentials(String email, String password) async {
    try {
      await _secure.write(key: _secureKeyEmail, value: email);
      await _secure.write(key: _secureKeyPassword, value: password);
    } catch (e, st) {
      // A keystore failure (locked device, corrupt entry) shouldn't break
      // the login that just succeeded — the refresh-token path still works.
      log.w('[storage] saveCredentials failed: $e', stackTrace: st);
    }
  }

  Future<({String email, String password})?> getCredentials() async {
    try {
      final email = await _secure.read(key: _secureKeyEmail);
      final password = await _secure.read(key: _secureKeyPassword);
      if (email == null || password == null) return null;
      if (email.isEmpty || password.isEmpty) return null;
      return (email: email, password: password);
    } catch (e, st) {
      log.w('[storage] getCredentials failed: $e', stackTrace: st);
      return null;
    }
  }

  Future<void> clearCredentials() async {
    try {
      await _secure.delete(key: _secureKeyEmail);
      await _secure.delete(key: _secureKeyPassword);
    } catch (e, st) {
      log.w('[storage] clearCredentials failed: $e', stackTrace: st);
    }
  }

  // --- Recent Searches ---

  List<String> getRecentSearches() {
    final key = _userKeyOrNull('recent_searches');
    if (key == null) return const [];
    final raw = _box.get(key);
    if (raw is List) {
      return raw.whereType<String>().toList();
    }
    return const [];
  }

  Future<void> addRecentSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final current = getRecentSearches();
    final filtered = current
        .where((s) => s.toLowerCase() != q.toLowerCase())
        .toList();
    filtered.insert(0, q);
    if (filtered.length > _recentSearchesMax) {
      filtered.removeRange(_recentSearchesMax, filtered.length);
    }
    await _box.put(_userKey('recent_searches'), filtered);
  }

  Future<void> removeRecentSearch(String query) async {
    final current = getRecentSearches();
    final filtered = current
        .where((s) => s.toLowerCase() != query.trim().toLowerCase())
        .toList();
    final key = _userKeyOrNull('recent_searches');
    if (key == null) return;
    await _box.put(key, filtered);
  }

  Future<void> clearRecentSearches() async {
    final key = _userKeyOrNull('recent_searches');
    if (key == null) return;
    await _box.delete(key);
  }

  Future<void> saveUser(Map<String, dynamic> userJson) async {
    await _box.put('user_profile', jsonEncode(userJson));
  }

  Map<String, dynamic>? getUser() {
    final String? userStr = _box.get('user_profile');
    if (userStr != null) {
      return jsonDecode(userStr);
    }
    return null;
  }

  // --- Editor annotations (per-section margin notes) ---
  // Stored as a list of JSON-encoded annotation strings, keyed by section.
  // Per-user-scoped so opening a different account doesn't surface another
  // user's notes.

  String _annotationsKey(String sectionId) =>
      _userKey('annotations__$sectionId');

  String? _annotationsKeyOrNull(String sectionId) =>
      _userKeyOrNull('annotations__$sectionId');

  List<String> getAnnotationStringsForSection(String sectionId) {
    final key = _annotationsKeyOrNull(sectionId);
    if (key == null) return const [];
    final raw = _box.get(key);
    if (raw is List) return raw.whereType<String>().toList();
    return const [];
  }

  Future<void> saveAnnotationStringsForSection(
    String sectionId,
    List<String> jsonStrings,
  ) async {
    await _box.put(_annotationsKey(sectionId), jsonStrings);
  }

  Future<void> clearAnnotationsForSection(String sectionId) async {
    final key = _annotationsKeyOrNull(sectionId);
    if (key == null) return;
    await _box.delete(key);
  }

  // --- Section version history ---
  // Snapshots are list-of-JSON strings, ordered oldest → newest.

  String _versionsKey(String sectionId) =>
      _userKey('section_versions__$sectionId');

  String? _versionsKeyOrNull(String sectionId) =>
      _userKeyOrNull('section_versions__$sectionId');

  List<String> getVersionStringsForSection(String sectionId) {
    final key = _versionsKeyOrNull(sectionId);
    if (key == null) return const [];
    final raw = _box.get(key);
    if (raw is List) return raw.whereType<String>().toList();
    return const [];
  }

  Future<void> saveVersionStringsForSection(
    String sectionId,
    List<String> jsonStrings,
  ) async {
    await _box.put(_versionsKey(sectionId), jsonStrings);
  }

  Future<void> clearVersionsForSection(String sectionId) async {
    final key = _versionsKeyOrNull(sectionId);
    if (key == null) return;
    await _box.delete(key);
  }

  // --- Spell check ---

  static const String _keySpellEnabled = 'spell_check_enabled_v1';

  bool getSpellCheckEnabled() {
    return _box.get(_keySpellEnabled, defaultValue: true);
  }

  Future<void> saveSpellCheckEnabled(bool enabled) async {
    await _box.put(_keySpellEnabled, enabled);
  }

  /// Personal dictionary — words the user has marked "ignore". Per-user.
  List<String> getSpellCheckIgnored() {
    final key = _userKeyOrNull('spell_check_ignored');
    if (key == null) return const [];
    final raw = _box.get(key);
    if (raw is List) return raw.whereType<String>().toList();
    return const [];
  }

  Future<void> saveSpellCheckIgnored(List<String> words) async {
    await _box.put(_userKey('spell_check_ignored'), words);
  }

  // --- Linguistic Focus (POS-class highlighter) ---
  //
  // Persists the user's current overlay choice (one of the five
  // canonical class names from [LinguisticClass.all], or null = Off)
  // so the toggle survives app restarts. Stored as a plain string —
  // we don't import the class-name enum here to keep the storage
  // layer independent of the linguistic feature.
  static const String _keyLinguisticFocusClass = 'linguistic_focus_class_v1';

  String? getLinguisticFocusClass() {
    final raw = _box.get(_keyLinguisticFocusClass);
    if (raw is String && raw.isNotEmpty) return raw;
    return null;
  }

  Future<void> saveLinguisticFocusClass(String? className) async {
    if (className == null) {
      await _box.delete(_keyLinguisticFocusClass);
    } else {
      await _box.put(_keyLinguisticFocusClass, className);
    }
  }

  // --- Global dictionary cache (shared across users on this device) ---
  // Words are global; the version we hold is too. Not user-scoped — a
  // fresh login re-uses the same cache rather than re-downloading the
  // bundled base + every accumulated delta from scratch.
  //
  // Keys are language-scoped so a device that switches between locales
  // (en → es) keeps each cache distinct rather than mixing words from
  // unrelated dictionaries. Legacy un-scoped keys are migrated to `en`
  // on first read so existing installs don't lose their cached delta.

  static const String _legacyKeyDictWords = 'global_dictionary_words_v1';
  static const String _legacyKeyDictVersion = 'global_dictionary_version_v1';

  String _dictWordsKey(String lang) =>
      'global_dictionary_words_v1__${lang.toLowerCase()}';
  String _dictVersionKey(String lang) =>
      'global_dictionary_version_v1__${lang.toLowerCase()}';

  Set<String> getGlobalDictionaryWords({String language = 'en'}) {
    final raw = _box.get(_dictWordsKey(language));
    if (raw is List) return raw.whereType<String>().toSet();
    if (language.toLowerCase() == 'en') {
      // Fallback to the pre-multilang key so existing installs keep
      // their cached set on the first read after upgrade.
      final legacy = _box.get(_legacyKeyDictWords);
      if (legacy is List) return legacy.whereType<String>().toSet();
    }
    return <String>{};
  }

  Future<void> saveGlobalDictionaryWords(
    Set<String> words, {
    String language = 'en',
  }) async {
    await _box.put(_dictWordsKey(language), words.toList(growable: false));
  }

  int getGlobalDictionaryVersion({String language = 'en'}) {
    final raw = _box.get(_dictVersionKey(language));
    if (raw is int) return raw;
    if (language.toLowerCase() == 'en') {
      final legacy = _box.get(_legacyKeyDictVersion);
      if (legacy is int) return legacy;
    }
    return 0;
  }

  Future<void> saveGlobalDictionaryVersion(
    int version, {
    String language = 'en',
  }) async {
    await _box.put(_dictVersionKey(language), version);
  }

  // --- Feed cache (per-user) ---
  // Persists the personalized feed so an app restart can paint instantly
  // from disk while a silent network refresh runs in the background. Mirrors
  // the cache-first pattern Instagram / Twitter use on cold start.

  List<Map<String, dynamic>> getCachedFeedItems() {
    final key = _userKeyOrNull('feed_cache_v1');
    if (key == null) return const [];
    final raw = _box.get(key);
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (_) {}
    return const [];
  }

  Future<void> saveCachedFeedItems(List<Map<String, dynamic>> items) async {
    final key = _userKeyOrNull('feed_cache_v1');
    if (key == null) return;
    await _box.put(key, jsonEncode(items));
  }

  Future<void> clearCachedFeed() async {
    final key = _userKeyOrNull('feed_cache_v1');
    if (key == null) return;
    await _box.delete(key);
  }

  /// Drop any cached feed items whose `id` matches [feedItemId] or whose
  /// source-writing link (`bookId` / `writing_id`) matches [writingId].
  /// Called when the server confirms a feed card is gone (404 on fetch)
  /// or when the user deletes the source writing locally — either way,
  /// the next cold-start hydrate must not paint a stale card whose
  /// reader will crash on open.
  Future<void> removeCachedFeedItem({
    String? feedItemId,
    String? writingId,
  }) async {
    if (feedItemId == null && writingId == null) return;
    final key = _userKeyOrNull('feed_cache_v1');
    if (key == null) return;
    final items = getCachedFeedItems();
    if (items.isEmpty) return;
    final filtered = items.where((m) {
      if (feedItemId != null && m['id'] == feedItemId) return false;
      if (writingId != null) {
        final linked = m['bookId'] ?? m['writing_id'] ?? m['writingId'];
        if (linked == writingId) return false;
      }
      return true;
    }).toList();
    if (filtered.length == items.length) return;
    await _box.put(key, jsonEncode(filtered));
  }
}
