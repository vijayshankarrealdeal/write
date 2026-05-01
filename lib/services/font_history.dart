import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Tracks the user's recently-picked fonts (most recent first, deduped,
/// capped). The font picker surfaces these in a "Recent" section above
/// the curated/popular list.
class FontHistory {
  FontHistory._();
  static final FontHistory instance = FontHistory._();

  static const _key = 'font_history_v1';
  static const _max = 5;

  List<String> _recent = const [];
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final j = jsonDecode(raw);
        if (j is List) {
          _recent = [for (final e in j) if (e is String) e];
        }
      } catch (_) {
        // Corrupt blob — start fresh.
      }
    }
    _loaded = true;
  }

  List<String> get recent => List.unmodifiable(_recent);

  void add(String fontName) {
    if (fontName.isEmpty) return;
    final next = [fontName, ..._recent.where((n) => n != fontName)];
    _recent = next.length > _max ? next.sublist(0, _max) : next;
    SharedPreferences.getInstance().then(
      (p) => p.setString(_key, jsonEncode(_recent)),
    );
  }
}
