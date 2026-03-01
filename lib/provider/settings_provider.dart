import 'package:flutter/material.dart';
import 'package:writer/services/storage_service.dart';

class SettingsProvider extends ChangeNotifier {
  final StorageService _storage;

  SettingsProvider(this._storage) {
    _loadSettings();
  }

  // Application Theme State
  ThemeMode themeMode = ThemeMode.system;

  // Notification State
  bool notificationsEnabled = true;

  // Language State
  String selectedLanguage = "English (US)";

  // Sections view: 'grid' or 'list'
  bool sectionsGridView = true;

  final List<String> availableLanguages = [
    "English (US)",
    "English (UK)",
    "Spanish",
    "French",
    "German",
    "Chinese",
  ];

  void _loadSettings() {
    final mode = _storage.getThemeMode();
    if (mode == 'dark') {
      themeMode = ThemeMode.dark;
    } else if (mode == 'light') {
      themeMode = ThemeMode.light;
    } else {
      themeMode = ThemeMode.system;
    }

    sectionsGridView = _storage.getSectionsViewMode() == 'grid';
    notifyListeners();
  }

  void toggleSectionsView() {
    sectionsGridView = !sectionsGridView;
    _storage.saveSectionsViewMode(sectionsGridView ? 'grid' : 'list');
    notifyListeners();
  }

  void toggleTheme(bool isDark) {
    themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    _storage.saveThemeMode(isDark ? 'dark' : 'light');
    notifyListeners();
  }

  void toggleNotifications(bool value) {
    notificationsEnabled = value;
    notifyListeners();
  }

  void setLanguage(String lang) {
    selectedLanguage = lang;
    notifyListeners();
  }
}
