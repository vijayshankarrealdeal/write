import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persistent click counter for toolbar actions. Drives adaptive ordering
/// in the floating selection bar — what the user reaches for most ends up
/// closer to the front.
///
/// Usage is small (≤ 30 keys × int), so we keep it as a single JSON blob in
/// SharedPreferences instead of a dedicated Hive box. Loaded once at boot;
/// writes are debounced via the SharedPreferences async API.
class ToolbarUsage {
  ToolbarUsage._();
  static final ToolbarUsage instance = ToolbarUsage._();

  static const _key = 'toolbar_usage_v1';

  Map<String, int> _counts = const {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final j = jsonDecode(raw);
        if (j is Map) {
          _counts = {
            for (final e in j.entries)
              if (e.key is String && e.value is num)
                e.key as String: (e.value as num).toInt(),
          };
        }
      } catch (_) {
        // Corrupt blob — start fresh.
      }
    }
    _loaded = true;
  }

  int countOf(String id) => _counts[id] ?? 0;

  void increment(String id) {
    _counts = {..._counts, id: (_counts[id] ?? 0) + 1};
    // Fire-and-forget; ordering races are harmless for a usage counter.
    SharedPreferences.getInstance().then(
      (p) => p.setString(_key, jsonEncode(_counts)),
    );
  }

  /// Sort `ids` descending by usage; ties keep input order (stable).
  List<String> sortedByUsage(List<String> ids) {
    final indexed = [
      for (var i = 0; i < ids.length; i++) (ids[i], i),
    ];
    indexed.sort((a, b) {
      final ca = countOf(a.$1);
      final cb = countOf(b.$1);
      if (ca != cb) return cb.compareTo(ca);
      return a.$2.compareTo(b.$2);
    });
    return [for (final e in indexed) e.$1];
  }
}
