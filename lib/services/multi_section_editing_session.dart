import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/smart_substitutions.dart';
import 'package:inkspacex/services/spell_check_decoration.dart';

/// Live editing session for any view that mounts more than one
/// section at once — both Scrivenings (continuous scroll) and the
/// paginated Page view share this object.
///
/// Owns one [QuillController] per section so each editor has its own
/// document, undo stack, selection, and scroll. The provider creates a
/// session on entry to a multi-section view, registers sections lazily
/// as they enter the viewport, and disposes the session on exit. The
/// same instance survives a switch between Scrivenings and Page view
/// — only the renderer changes — so the cursor, undo stack, and
/// in-flight autosave timers are preserved across the swap.
///
/// Why a separate object (vs. inlining into EditorProvider): the session
/// is a self-contained, testable unit with a clear lifecycle. It also
/// keeps the per-section bookkeeping (timers, listeners, controllers)
/// out of the already-2k-line provider so the single-section editor
/// path stays readable.
///
/// The session does NOT touch persistence or the outbox itself — it
/// invokes [onSectionPersist] when a section's serialized content has
/// actually changed and lets the caller decide where to route the save.
class MultiSectionEditingSession {
  MultiSectionEditingSession({
    required this.book,
    required this.onSectionPersist,
    required this.onFocusChanged,
    required this.onTypingStateChanged,
    required this.smartSubstitutionsEnabled,
    required this.typingHapticsEnabled,
    Duration autoSaveDebounce = const Duration(seconds: 3),
  }) : _autoSaveDebounce = autoSaveDebounce;

  /// The book whose sections this session edits. The session does not
  /// re-read the book mid-flight; if the active book changes, the
  /// caller must dispose and recreate.
  final WritingModel book;

  /// Called with `(section, newContentJson)` whenever a section's
  /// content has actually changed and the autosave debounce fires.
  /// Caller persists locally and enqueues the outbox op.
  final Future<void> Function(SectionModel section, String contentJson)
      onSectionPersist;

  /// Called when keyboard focus moves to a different section so the
  /// caller can promote it to `activeSection` and keep chrome (spell
  /// check, inspector, annotations, version history, typewriter) bound
  /// to whichever section the cursor is in.
  final void Function(SectionModel section) onFocusChanged;

  /// Called with `true` on the first keystroke of a typing burst and
  /// `false` once all sections have flushed. Lets the caller surface a
  /// "Typing…" / "Saved" badge identical to single-section mode.
  final void Function(bool typing) onTypingStateChanged;

  /// Pull-style flag readers — the session calls these on each event so
  /// runtime toggling (settings sheet) takes effect immediately without
  /// needing to push state into the session.
  final bool Function() smartSubstitutionsEnabled;
  final bool Function() typingHapticsEnabled;

  final Duration _autoSaveDebounce;

  final Map<String, QuillController> _controllers = {};
  final Map<String, StreamSubscription<DocChange>> _subs = {};
  final Map<String, Timer> _autoSaveTimers = {};
  final Map<String, String> _lastSavedContent = {};
  final Map<String, FocusNode> _focusNodes = {};
  final Map<String, _FocusListener> _focusListeners = {};
  final Set<String> _typingSections = <String>{};

  String? _focusedSectionId;
  bool _disposed = false;
  bool _applyingSmartSubstitution = false;
  DateTime _lastHapticAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The section that currently owns keyboard focus, or `null` if no
  /// scrivenings editor has been focused yet this session.
  String? get focusedSectionId => _focusedSectionId;

  /// The QuillController for the focused section, or null if no section
  /// has been focused yet. The provider exposes this via its `controller`
  /// field so existing chrome (toolbar, find-replace, floating bars) keeps
  /// reading `provider.controller` and gets the right one without rewires.
  QuillController? get focusedController =>
      _focusedSectionId == null ? null : _controllers[_focusedSectionId];

  /// Snapshot of currently registered (mounted) sections. Useful for
  /// flush-on-exit and tests.
  List<String> get registeredSectionIds => _controllers.keys.toList();

  /// True while at least one section is in the typing-debounce window.
  bool get isTyping => _typingSections.isNotEmpty;

  bool get isDisposed => _disposed;

  /// Build (or fetch) the QuillController for [section]. Idempotent —
  /// repeated calls return the same controller so a ListView.builder
  /// rebuild is cheap. The doc-changes listener is attached on first
  /// register so per-section autosave runs from the moment a section
  /// is mounted.
  ///
  /// Late-binding behaviour: the section's `content` is read at register
  /// time. If the underlying section's content changed externally (e.g.
  /// remote sync) between registers, the cached controller will not
  /// reflect that. Call [refreshSectionContent] to force a rebuild.
  QuillController register(SectionModel section) {
    _checkNotDisposed();
    final existing = _controllers[section.id];
    if (existing != null) return existing;

    final controller = _buildController(section.content);
    _controllers[section.id] = controller;
    _lastSavedContent[section.id] = _serialize(controller);
    _subs[section.id] = controller.document.changes.listen(
      (event) => _onDocChange(section, controller, event),
    );
    return controller;
  }

  /// Update the in-memory controller for [section] from the latest
  /// `section.content`. Used when a remote sync or merge changes a
  /// section while scrivenings is open. Preserves selection if it's
  /// still in range; otherwise clamps to the document end.
  void refreshSectionContent(SectionModel section) {
    final c = _controllers[section.id];
    if (c == null) return;
    if (_serialize(c) == section.content) return;
    final newDoc = _buildDocument(section.content);
    final oldSel = c.selection;
    c.document = newDoc;
    final maxOffset = newDoc.length - 1;
    final restored = TextSelection.collapsed(
      offset: oldSel.baseOffset.clamp(0, maxOffset < 0 ? 0 : maxOffset),
    );
    c.updateSelection(restored, ChangeSource.silent);
    _lastSavedContent[section.id] = section.content;
  }

  /// Get (or create) the FocusNode for [section]. The node fires
  /// [onFocusChanged] when it gains focus so the caller can promote
  /// the section. The session owns the node lifetime — do not dispose
  /// from outside.
  FocusNode focusNode(SectionModel section) {
    _checkNotDisposed();
    final existing = _focusNodes[section.id];
    if (existing != null) return existing;
    final node = FocusNode(debugLabel: 'multiSection:${section.id}');
    final listener = _FocusListener(node, () {
      if (node.hasFocus) {
        _focusedSectionId = section.id;
        onFocusChanged(section);
      }
    });
    listener.attach();
    _focusNodes[section.id] = node;
    _focusListeners[section.id] = listener;
    return node;
  }

  /// Drop the controller and listeners for [sectionId] and flush any
  /// pending autosave first. Called when a section unmounts (scrolls
  /// out of the cache window) or is deleted.
  Future<void> unregister(String sectionId) async {
    final timer = _autoSaveTimers.remove(sectionId);
    if (timer?.isActive ?? false) {
      timer!.cancel();
      await _flushSection(sectionId);
    }
    await _subs.remove(sectionId)?.cancel();
    final c = _controllers.remove(sectionId);
    c?.dispose();
    _lastSavedContent.remove(sectionId);
    final listener = _focusListeners.remove(sectionId);
    listener?.detach();
    _focusNodes.remove(sectionId)?.dispose();
    if (_focusedSectionId == sectionId) {
      _focusedSectionId = null;
    }
    _typingSections.remove(sectionId);
    if (_typingSections.isEmpty) onTypingStateChanged(false);
  }

  /// Flush every pending autosave timer immediately. Called on exit
  /// from scrivenings mode and on app pause so the user doesn't lose
  /// work in flight.
  Future<void> flushAll() async {
    final ids = _autoSaveTimers.keys.toList();
    for (final id in ids) {
      _autoSaveTimers.remove(id)?.cancel();
      await _flushSection(id);
    }
    if (_typingSections.isNotEmpty) {
      _typingSections.clear();
      onTypingStateChanged(false);
    }
  }

  /// Tear down the entire session. Flushes pending writes, cancels all
  /// listeners and timers, and disposes every controller and focus node.
  /// Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await flushAll();
    for (final sub in _subs.values) {
      await sub.cancel();
    }
    _subs.clear();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    for (final entry in _focusListeners.entries) {
      entry.value.detach();
    }
    _focusListeners.clear();
    for (final n in _focusNodes.values) {
      n.dispose();
    }
    _focusNodes.clear();
    _lastSavedContent.clear();
    _typingSections.clear();
  }

  /// Force the focused-section pointer to [sectionId] without changing
  /// real focus. Used when the session restores focus after a rebuild.
  /// No-op if the section is not registered.
  @visibleForTesting
  void debugSetFocused(String sectionId) {
    if (!_controllers.containsKey(sectionId)) return;
    _focusedSectionId = sectionId;
  }

  // ───────────────────────── internals ─────────────────────────

  void _onDocChange(
    SectionModel section,
    QuillController controller,
    DocChange event,
  ) {
    if (_disposed) return;
    // Spell-check decoration mutations are silent — they must not
    // trigger autosave or smart substitutions.
    if (event.source == ChangeSource.silent) return;
    _maybeSmartSubstitute(section, controller, event);
    _maybeTypingHaptic(event);
    _scheduleAutoSave(section.id);
  }

  void _scheduleAutoSave(String sectionId) {
    if (_typingSections.add(sectionId)) {
      if (_typingSections.length == 1) onTypingStateChanged(true);
    }
    _autoSaveTimers[sectionId]?.cancel();
    _autoSaveTimers[sectionId] = Timer(_autoSaveDebounce, () async {
      await _flushSection(sectionId);
    });
  }

  Future<void> _flushSection(String sectionId) async {
    final controller = _controllers[sectionId];
    if (controller == null) {
      _typingSections.remove(sectionId);
      if (_typingSections.isEmpty) onTypingStateChanged(false);
      return;
    }
    final section = _findSection(sectionId);
    if (section == null) {
      _typingSections.remove(sectionId);
      if (_typingSections.isEmpty) onTypingStateChanged(false);
      return;
    }
    final current = _serialize(controller);
    final last = _lastSavedContent[sectionId];
    if (current != last) {
      try {
        await onSectionPersist(section, current);
        _lastSavedContent[sectionId] = current;
      } catch (_) {
        // The caller is responsible for retrying via the outbox/drainer.
        // We swallow here so a transient failure doesn't poison the
        // typing state — the next keystroke re-arms the timer.
      }
    }
    _typingSections.remove(sectionId);
    if (_typingSections.isEmpty) onTypingStateChanged(false);
  }

  SectionModel? _findSection(String sectionId) {
    for (final s in book.sections) {
      if (s.id == sectionId) return s;
    }
    return null;
  }

  void _maybeSmartSubstitute(
    SectionModel section,
    QuillController controller,
    DocChange event,
  ) {
    if (!smartSubstitutionsEnabled()) return;
    if (_applyingSmartSubstitution) return;
    if (event.source != ChangeSource.local) return;

    int retain = 0;
    String? inserted;
    int? insertOffset;
    for (final op in event.change.toList()) {
      if (op.isRetain) {
        retain += (op.value as int? ?? 0);
      } else if (op.isInsert) {
        if (op.data is! String) return;
        if (inserted != null) return;
        inserted = op.data as String;
        insertOffset = retain;
        retain += inserted.length;
      } else if (op.isDelete) {
        return;
      }
    }
    if (inserted == null || insertOffset == null) return;

    final sub = SmartSubstitutions.compute(
      textAfter: controller.document.toPlainText(),
      insertOffset: insertOffset,
      inserted: inserted,
    );
    if (sub == null) return;

    _applyingSmartSubstitution = true;
    try {
      controller.replaceText(
        sub.start,
        sub.length,
        sub.replacement,
        TextSelection.collapsed(offset: sub.cursorAfter),
      );
    } finally {
      _applyingSmartSubstitution = false;
    }
  }

  void _maybeTypingHaptic(DocChange event) {
    if (!typingHapticsEnabled()) return;
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    String? inserted;
    for (final op in event.change.toList()) {
      if (op.isInsert && op.data is String) inserted = op.data as String;
    }
    if (inserted == null || inserted.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_lastHapticAt).inMilliseconds < 120) return;
    if (inserted.contains('\n')) {
      _lastHapticAt = now;
      HapticFeedback.lightImpact();
      return;
    }
    final last = inserted[inserted.length - 1];
    if (last == '.' || last == '!' || last == '?') {
      _lastHapticAt = now;
      HapticFeedback.selectionClick();
    }
  }

  String _serialize(QuillController controller) {
    final clean = stripSpellCheckErrors(controller.document.toDelta());
    return jsonEncode(clean.toJson());
  }

  QuillController _buildController(String content) {
    return QuillController(
      document: _buildDocument(content),
      selection: const TextSelection.collapsed(offset: 0),
    );
  }

  Document _buildDocument(String content) {
    final raw = content.trim();
    if (raw.isEmpty) {
      return Document()..insert(0, '');
    }
    try {
      final ops = jsonDecode(raw);
      if (ops is List) return Document.fromJson(ops);
    } catch (_) {}
    return Document()..insert(0, content);
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('MultiSectionEditingSession used after dispose()');
    }
  }
}

class _FocusListener {
  _FocusListener(this.node, this.onChange);
  final FocusNode node;
  final VoidCallback onChange;

  void attach() => node.addListener(onChange);
  void detach() => node.removeListener(onChange);
}
