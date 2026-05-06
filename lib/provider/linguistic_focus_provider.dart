import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart' show QuillController;

import 'package:inkspacex/services/linguistic_focus_decoration.dart';
import 'package:inkspacex/services/linguistic_focus_service.dart';
import 'package:inkspacex/services/storage_service.dart';

/// Drives the editor's linguistic-focus overlay.
///
/// State flow:
///
/// 1. UI sets [activeClass] to one of the five canonical names (or
///    null = Off). The provider persists the choice via
///    [StorageService] so it survives app restarts and section
///    swaps.
/// 2. On a class change, or whenever the attached document mutates,
///    we schedule a debounced (500ms) fetch against
///    `/api/linguistic/tag`.
/// 3. Results land back, get filtered to the active class, and are
///    pushed through [applyLinguisticFocus] which paints the
///    highlight + dim layer on the Quill controller.
/// 4. Toggling Off clears all marks in a single silent compose.
///
/// Debounce + sequence number drop late results when the user is
/// typing fast — exactly the same pattern as [SpellCheckProvider]
/// and for the same reason: a slow earlier scan must not overwrite a
/// fresher one.
class LinguisticFocusProvider extends ChangeNotifier {
  LinguisticFocusProvider(this._storage, this._service) {
    _activeClass = _storage.getLinguisticFocusClass();
  }

  final StorageService _storage;
  final LinguisticFocusService _service;

  /// 500ms is the spec'd debounce. Slightly longer than spell check
  /// (700ms there) feels right — POS tagging is heavier on the
  /// backend so we shouldn't hammer it on every word.
  @visibleForTesting
  static const Duration debounce = Duration(milliseconds: 500);

  String? _activeClass;
  LinguisticTagResult _lastResult = LinguisticTagResult.empty;
  bool _scanning = false;
  bool _hasScanned = false;
  // True iff the last scan came back from a backend without spaCy.
  // The toggle UI surfaces a hint so the user knows POS classes are
  // unavailable (dialogue still works).
  bool _posUnavailable = false;
  Timer? _debounceTimer;
  QuillController? _attached;
  VoidCallback? _listener;
  String _lastScannedText = '';
  int _scanSeq = 0;

  String? get activeClass => _activeClass;
  bool get scanning => _scanning;
  bool get hasScanned => _hasScanned;
  bool get posUnavailable => _posUnavailable;
  LinguisticTagResult get lastResult => _lastResult;

  /// Number of spans currently highlighted (after class filtering).
  /// Used by the toggle UI's "12 adverbs" status hint.
  int get matchCount {
    final c = _activeClass;
    if (c == null) return 0;
    return _lastResult.spansFor(c).length;
  }

  /// Switch the active class, persist, and refresh the overlay. A
  /// null value clears everything.
  Future<void> setActiveClass(String? className) async {
    if (_activeClass == className) return;
    _activeClass = className;
    await _storage.saveLinguisticFocusClass(className);
    final c = _attached;
    if (className == null) {
      _debounceTimer?.cancel();
      if (c != null) {
        applyLinguisticFocus(
          c,
          activeClass: null,
          highlightSpans: const [],
        );
      }
      notifyListeners();
      return;
    }
    // If we already have results from a prior class, repaint with the
    // new spans without waiting on the network — instant feedback.
    if (c != null && _hasScanned) {
      applyLinguisticFocus(
        c,
        activeClass: className,
        highlightSpans: _lastResult.spansFor(className),
      );
    }
    // Always (re-)scan: the previous result might have been from a
    // narrower class set, and the doc may have changed since.
    // Run *immediately* (not debounced) — the user just made a
    // deliberate UI choice and expects the new highlight to land in
    // a visual frame, not after a 500ms typing delay.
    if (c != null) {
      _debounceTimer?.cancel();
      _lastScannedText = '';
      unawaited(_runScan(c));
    }
    notifyListeners();
  }

  /// Wire the provider to a Quill controller. Call on section change.
  /// Idempotent — re-attaching the same controller is a no-op.
  void attach(QuillController controller) {
    if (_attached == controller && _listener != null) return;
    detach();
    _attached = controller;
    _lastScannedText = '';
    _hasScanned = false;
    void listener() => _scheduleScan(controller);
    _listener = listener;
    controller.addListener(listener);
    if (_activeClass != null) {
      // Run the first scan immediately so the user doesn't see a
      // 500ms blank-overlay flicker on section open.
      unawaited(_runScan(controller));
    }
  }

  void detach() {
    final c = _attached;
    final l = _listener;
    if (c != null && l != null) c.removeListener(l);
    _attached = null;
    _listener = null;
    _debounceTimer?.cancel();
    _lastScannedText = '';
    _hasScanned = false;
    _lastResult = LinguisticTagResult.empty;
    notifyListeners();
  }

  void _scheduleScan(QuillController controller) {
    if (_activeClass == null) return;
    final text = controller.document.toPlainText();
    // Skip silent composes from our own decoration (text unchanged).
    if (text == _lastScannedText) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => _runScan(controller));
  }

  Future<void> _runScan(QuillController controller) async {
    final text = controller.document.toPlainText();
    final mySeq = ++_scanSeq;
    _scanning = true;
    notifyListeners();
    final result = await _service.tag(text);
    if (_attached != controller) return;
    if (mySeq != _scanSeq) return;
    _lastResult = result;
    _lastScannedText = text;
    _scanning = false;
    _hasScanned = true;
    _posUnavailable = !result.posAvailable;
    final c = _activeClass;
    if (c != null) {
      applyLinguisticFocus(
        controller,
        activeClass: c,
        highlightSpans: result.spansFor(c),
      );
    }
    notifyListeners();
  }

  @override
  void dispose() {
    detach();
    super.dispose();
  }
}
