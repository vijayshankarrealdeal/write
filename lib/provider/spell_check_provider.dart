import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart' show QuillController;

import 'package:inkspacex/services/dictionary_service.dart';
import 'package:inkspacex/services/spell_check_decoration.dart';
import 'package:inkspacex/services/spell_check_service.dart';
import 'package:inkspacex/services/storage_service.dart';

/// Holds the current section's misspelling list and re-runs the scan when
/// the document changes (debounced so we don't churn on every keystroke).
/// Toggle persists across sessions via [StorageService].
class SpellCheckProvider extends ChangeNotifier {
  SpellCheckProvider(this._storage, this._service, this._dictionary) {
    _enabled = _storage.getSpellCheckEnabled();
  }

  final StorageService _storage;
  final SpellCheckService _service;
  final DictionaryService _dictionary;
  static const Duration _debounce = Duration(milliseconds: 700);

  bool _enabled = true;
  List<Misspelling> _issues = const [];
  // Sorted-by-start view of [_issues] for binary-search caret lookup.
  // The InlineSpellCheckBar's listener calls [issueAt] on every keystroke,
  // so we keep this hot path off a linear scan.
  List<Misspelling> _issuesByStart = const [];
  bool _scanning = false;
  // Flips true after the first scan resolves for the currently attached
  // controller. The status chip uses it to show "Checking…" on entry
  // instead of falsely flashing "No issues" before results arrive.
  bool _hasScanned = false;
  Timer? _debounceTimer;
  QuillController? _attached;
  VoidCallback? _listener;
  // Personal dictionary — words the user explicitly accepted. Skipped on
  // the next scan. Persisted per user, not per section.
  Set<String> _ignored = <String>{};
  // The plain text of the last network scan. The controller listener
  // fires on every document change — including the silent decoration
  // composes we issue ourselves — so we gate work on real text changes.
  String _lastScannedText = '';
  // Bumped on every scan kickoff. Late-arriving responses with a stale
  // generation are dropped so a slow earlier scan can't overwrite the
  // results of a newer one when the user is typing fast.
  int _scanSeq = 0;

  bool get enabled => _enabled;
  List<Misspelling> get issues => List.unmodifiable(_issues);
  bool get scanning => _scanning;
  bool get hasScanned => _hasScanned;
  Set<String> get ignored => Set.unmodifiable(_ignored);

  Future<void> setEnabled(bool v) async {
    if (_enabled == v) return;
    _enabled = v;
    await _storage.saveSpellCheckEnabled(v);
    if (!v) {
      _setIssues(const []);
      _debounceTimer?.cancel();
      final c = _attached;
      if (c != null) applySpellCheckErrors(c, const []);
    } else if (_attached != null) {
      _lastScannedText = '';
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
    _lastScannedText = '';
    _hasScanned = false;
    void listener() => _scheduleScan(controller);
    _listener = listener;
    controller.addListener(listener);
    // Run the first scan immediately rather than waiting on the typing
    // debounce — the user just opened the section and expects underlines
    // (and a real "Checking…/N issues" status) without an 800ms delay.
    if (_enabled) unawaited(_runScan(controller));
  }

  void detach() {
    final c = _attached;
    final l = _listener;
    if (c != null && l != null) c.removeListener(l);
    _attached = null;
    _listener = null;
    _debounceTimer?.cancel();
    _setIssues(const []);
    _lastScannedText = '';
    _hasScanned = false;
    notifyListeners();
  }

  /// Single point of truth for swapping the issues list. Keeps the
  /// sorted-by-start mirror used by [issueAt] in lockstep so the inline
  /// bar's per-keystroke caret check stays O(log n).
  void _setIssues(List<Misspelling> next) {
    _issues = next;
    if (next.isEmpty) {
      _issuesByStart = const [];
      return;
    }
    final sorted = List<Misspelling>.from(next);
    sorted.sort((a, b) => a.start.compareTo(b.start));
    _issuesByStart = sorted;
  }

  /// Top suggestions for a misspelled word. Backend-served; returns empty
  /// on offline or transient API failure.
  Future<List<String>> suggest(String word, {int max = 5}) =>
      _service.suggest(word, max: max);

  /// The misspelling whose span contains [offset], or null if the cursor
  /// is outside every issue range. Used by the inline correction bar to
  /// decide whether to surface itself for the current caret position.
  Misspelling? issueAt(int offset) {
    final list = _issuesByStart;
    if (list.isEmpty) return null;
    // Binary search for the rightmost issue with start <= offset, then
    // verify the cursor is still inside its span.
    var lo = 0, hi = list.length - 1, idx = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].start <= offset) {
        idx = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (idx < 0) return null;
    final m = list[idx];
    return offset <= m.end ? m : null;
  }

  /// Permanently add a word to the user's personal dictionary. Future
  /// scans (in this and other sections) will treat the word as known.
  ///
  /// Also fires off a best-effort POST to `/api/dictionary/submit` so the
  /// word lands in the admin's merge queue. The submit is fire-and-forget
  /// — a failed network call must never break the local "Add to
  /// dictionary" gesture, since the user expects the underline to vanish
  /// immediately regardless of connectivity.
  Future<void> addToDictionary(String word) async {
    final lower = word.toLowerCase();
    if (_ignored.contains(lower)) return;
    _ignored = {..._ignored, lower};
    await _storage.saveSpellCheckIgnored(_ignored.toList());
    _setIssues(
        _issues.where((i) => i.word.toLowerCase() != lower).toList());
    final c = _attached;
    if (c != null) applySpellCheckErrors(c, _issues);
    unawaited(_dictionary.submitWord(lower));
    notifyListeners();
  }

  /// Drop a single issue from the current scan results without persisting.
  /// The next document change re-runs the scan and may surface it again.
  void dismissIssue(Misspelling m) {
    final before = _issues.length;
    final next = _issues
        .where((i) =>
            !(i.start == m.start && i.length == m.length && i.word == m.word))
        .toList();
    if (next.length == before) return;
    _setIssues(next);
    final c = _attached;
    if (c != null) applySpellCheckErrors(c, _issues);
    notifyListeners();
  }

  void _scheduleScan(QuillController controller) {
    if (!_enabled) return;
    // Skip when the document text is unchanged. Quill emits change
    // notifications for our own decoration composes too; without this
    // guard each apply would queue another scan in a loop.
    if (controller.document.toPlainText() == _lastScannedText) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () => _runScan(controller));
  }

  Future<void> _runScan(QuillController controller) async {
    final text = controller.document.toPlainText();
    final mySeq = ++_scanSeq;
    _scanning = true;
    notifyListeners();
    final raw = await _service.check(text, ignored: _ignored);
    if (_attached != controller) return;
    // A newer scan was kicked off (or the controller was swapped) while
    // we awaited the network — drop this stale result rather than letting
    // it overwrite the fresher issue list.
    if (mySeq != _scanSeq) return;
    // Server already filters out the ignored personal-dictionary words.
    _setIssues(raw);
    _lastScannedText = text;
    _scanning = false;
    _hasScanned = true;
    applySpellCheckErrors(controller, _issues);
    notifyListeners();
  }

  @override
  void dispose() {
    detach();
    super.dispose();
  }
}
