import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart' show QuillController;

import 'package:inkspacex/services/spell_check_service.dart';
import 'package:inkspacex/services/storage_service.dart';

/// Holds the current section's misspelling list and re-runs the scan when
/// the document changes (debounced ~600ms so we don't churn on every
/// keystroke). Toggle persists across sessions via [StorageService].
class SpellCheckProvider extends ChangeNotifier {
  SpellCheckProvider(this._storage, this._service) {
    _enabled = _storage.getSpellCheckEnabled();
  }

  final StorageService _storage;
  final SpellCheckService _service;
  // Slightly longer than the local debounce — checks are now a network
  // round trip, so we let the user keep typing a bit longer before firing.
  static const Duration _debounce = Duration(milliseconds: 800);

  bool _enabled = true;
  List<Misspelling> _issues = const [];
  bool _scanning = false;
  Timer? _debounceTimer;
  QuillController? _attached;
  VoidCallback? _listener;
  // Personal dictionary — words the user explicitly accepted. Skipped on
  // the next scan. Persisted per user, not per section.
  Set<String> _ignored = <String>{};

  bool get enabled => _enabled;
  List<Misspelling> get issues => List.unmodifiable(_issues);
  bool get scanning => _scanning;
  Set<String> get ignored => Set.unmodifiable(_ignored);

  Future<void> setEnabled(bool v) async {
    if (_enabled == v) return;
    _enabled = v;
    await _storage.saveSpellCheckEnabled(v);
    if (!v) {
      _issues = const [];
      _debounceTimer?.cancel();
    } else if (_attached != null) {
      _scheduleScan(_attached!);
    }
    notifyListeners();
  }

  /// Wire the provider to a Quill controller. Call on section change. Safe
  /// to call repeatedly with the same controller — the listener is only
  /// attached once.
  void attach(QuillController controller) {
    if (_attached == controller && _listener != null) return;
    detach();
    _attached = controller;
    _ignored = _storage.getSpellCheckIgnored().toSet();
    void listener() => _scheduleScan(controller);
    _listener = listener;
    controller.addListener(listener);
    if (_enabled) _scheduleScan(controller);
  }

  void detach() {
    final c = _attached;
    final l = _listener;
    if (c != null && l != null) c.removeListener(l);
    _attached = null;
    _listener = null;
    _debounceTimer?.cancel();
    _issues = const [];
    notifyListeners();
  }

  /// Top suggestions for a misspelled word. Backend-served; returns empty
  /// on offline or transient API failure.
  Future<List<String>> suggest(String word, {int max = 5}) =>
      _service.suggest(word, max: max);

  Future<void> ignoreWord(String word) async {
    final lower = word.toLowerCase();
    if (_ignored.contains(lower)) return;
    _ignored = {..._ignored, lower};
    await _storage.saveSpellCheckIgnored(_ignored.toList());
    _issues =
        _issues.where((i) => i.word.toLowerCase() != lower).toList();
    notifyListeners();
  }

  void _scheduleScan(QuillController controller) {
    if (!_enabled) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () => _runScan(controller));
  }

  Future<void> _runScan(QuillController controller) async {
    final text = controller.document.toPlainText();
    _scanning = true;
    notifyListeners();
    final raw = await _service.check(text, ignored: _ignored);
    if (_attached != controller) return;
    // Server already filters out the ignored personal-dictionary words.
    _issues = raw;
    _scanning = false;
    notifyListeners();
  }

  @override
  void dispose() {
    detach();
    super.dispose();
  }
}
