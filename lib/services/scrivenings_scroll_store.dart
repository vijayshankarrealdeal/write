import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists Scrivenings continuous-scroll position per book so reopening
/// a project drops the user back where they left off in the multi-
/// section view. Pixel offsets are saved and restored as-is; if the
/// user reordered or deleted sections in the meantime the offset may
/// land on different content, which is acceptable — the alternative
/// (anchor by section + intra-section offset) costs more bookkeeping
/// without meaningfully better UX.
class ScrivenningsScrollStore {
  const ScrivenningsScrollStore();

  static const String _prefix = 'scrivenings.scroll.v1.';

  /// In-memory backing for tests so a tester can inject an empty map
  /// without setting up SharedPreferences. Production calls use the
  /// real [SharedPreferences.getInstance].
  static Map<String, double>? _testStore;

  /// Set an in-memory store. Pass null to restore real prefs.
  /// Test-only — do not call from app code.
  static void debugUseMemoryStore(Map<String, double>? store) {
    _testStore = store;
  }

  Future<double?> read(String bookId) async {
    if (bookId.isEmpty) return null;
    final mem = _testStore;
    if (mem != null) return mem['$_prefix$bookId'];
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble('$_prefix$bookId');
  }

  Future<void> write(String bookId, double offset) async {
    if (bookId.isEmpty) return;
    final mem = _testStore;
    if (mem != null) {
      mem['$_prefix$bookId'] = offset;
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('$_prefix$bookId', offset);
  }

  Future<void> clear(String bookId) async {
    if (bookId.isEmpty) return;
    final mem = _testStore;
    if (mem != null) {
      mem.remove('$_prefix$bookId');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$bookId');
  }
}
