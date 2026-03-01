import 'package:flutter/material.dart';

class SettingsProvider extends ChangeNotifier {
  // Application Theme State
  ThemeMode themeMode = ThemeMode.system;

  // Notification State
  bool notificationsEnabled = true;

  // Language State
  String selectedLanguage = "English (US)";

  final List<String> availableLanguages = [
    "English (US)",
    "English (UK)",
    "Spanish",
    "French",
    "German",
  ];

  void toggleTheme(bool isDark) {
    themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
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
