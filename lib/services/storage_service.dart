import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:writer/models/writing_model.dart';

class StorageService {
  static const String _boxName = 'writer_app_box';
  static const String _keyBooks = 'user_books_json';
  static const String _keyTheme = 'app_theme_mode';
  static const String _keyOnboarding = 'onboarding_complete';
  static const String _keyAuthToken = 'auth_token';

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

  // --- Onboarding & Auth ---

  bool isOnboardingComplete() {
    return _box.get(_keyOnboarding, defaultValue: false);
  }

  Future<void> completeOnboarding() async {
    await _box.put(_keyOnboarding, true);
  }

  String? getAuthToken() {
    return _box.get(_keyAuthToken);
  }

  Future<void> saveAuthToken(String token) async {
    await _box.put(_keyAuthToken, token);
  }

  Future<void> clearAuth() async {
    await _box.delete(_keyAuthToken);
    await _box.delete('user_profile');
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
