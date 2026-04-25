import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:inkspacex/models/writing_model.dart';

class StorageService {
  static const String _boxName = 'writer_app_box';
  static const String _keyBooks = 'user_books_json';
  static const String _keyTheme = 'app_theme_mode';
  static const String _keyOnboarding = 'onboarding_complete';
  static const String _keyAuthToken = 'auth_token';
  static const String _keyRefreshToken = 'refresh_token';
  static const String _keyOnboardingPrefs = 'onboarding_preferences';
  static const String _keySectionsViewMode = 'sections_view_mode';
  static const String _keyRecentSearches = 'recent_searches';
  static const int _recentSearchesMax = 8;

  late Box _box;

  Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox(_boxName);
  }

  // --- Books Storage ---

  List<WritingModel> getBooks() {
    final rawList = _box.get(_keyBooks, defaultValue: <String>[]);
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
    await _box.put(_keyBooks, encodedList);
  }

  Future<void> clearBooks() async {
    await _box.delete(_keyBooks);
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

  // --- Recent Searches ---

  List<String> getRecentSearches() {
    final raw = _box.get(_keyRecentSearches);
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
    await _box.put(_keyRecentSearches, filtered);
  }

  Future<void> removeRecentSearch(String query) async {
    final current = getRecentSearches();
    final filtered = current
        .where((s) => s.toLowerCase() != query.trim().toLowerCase())
        .toList();
    await _box.put(_keyRecentSearches, filtered);
  }

  Future<void> clearRecentSearches() async {
    await _box.delete(_keyRecentSearches);
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
}
