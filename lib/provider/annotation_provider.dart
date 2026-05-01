import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:inkspacex/models/editor_annotation_model.dart';
import 'package:inkspacex/services/storage_service.dart';

/// Per-section annotations, persisted to Hive via [StorageService].
/// One provider instance lives for the whole app; `loadForSection` switches
/// the working set whenever the user opens a different section.
class AnnotationProvider extends ChangeNotifier {
  AnnotationProvider(this._storage);

  final StorageService _storage;

  String? _sectionId;
  List<EditorAnnotation> _annotations = const [];

  String? get sectionId => _sectionId;
  List<EditorAnnotation> get annotations => List.unmodifiable(_annotations);

  int get unresolvedCount =>
      _annotations.where((a) => !a.resolved && !a.orphaned).length;

  /// Switch the working set to a different section. Pass the current
  /// document's plain text so anchors that drifted due to edits made in
  /// other clients can be reconciled.
  void loadForSection(String sectionId, String documentPlainText) {
    _sectionId = sectionId;
    final raw = _storage.getAnnotationStringsForSection(sectionId);
    final loaded = <EditorAnnotation>[];
    for (final s in raw) {
      try {
        loaded.add(EditorAnnotation.decode(s));
      } catch (_) {
        // Drop unreadable entries silently — better than crashing the editor.
      }
    }
    _annotations = loaded
        .map((a) => _reconcileAnchor(a, documentPlainText))
        .toList();
    notifyListeners();
  }

  void clear() {
    _sectionId = null;
    _annotations = const [];
    notifyListeners();
  }

  Future<EditorAnnotation> add({
    required String authorId,
    required String authorName,
    required String body,
    required int anchorStart,
    required int anchorLength,
    required String anchoredText,
  }) async {
    final sid = _sectionId;
    if (sid == null) {
      throw StateError('No active section — call loadForSection first.');
    }
    final now = DateTime.now();
    final entry = EditorAnnotation(
      id: _newId(),
      sectionId: sid,
      authorId: authorId,
      authorName: authorName,
      body: body,
      anchorStart: anchorStart,
      anchorLength: anchorLength,
      anchoredText: anchoredText,
      createdAt: now,
      updatedAt: now,
    );
    _annotations = [..._annotations, entry];
    await _persist();
    notifyListeners();
    return entry;
  }

  Future<void> updateBody(String id, String body) async {
    _annotations = _annotations
        .map((a) =>
            a.id == id ? a.copyWith(body: body, updatedAt: DateTime.now()) : a)
        .toList();
    await _persist();
    notifyListeners();
  }

  Future<void> setResolved(String id, bool resolved) async {
    _annotations = _annotations
        .map((a) => a.id == id ? a.copyWith(resolved: resolved) : a)
        .toList();
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _annotations = _annotations.where((a) => a.id != id).toList();
    await _persist();
    notifyListeners();
  }

  /// Reflow anchors after a local edit. Cheaper than re-anchoring against
  /// `anchoredText` for every change — we just shift offsets that sit
  /// after the edit point. Call this with `(editPos, oldLen, newLen)`
  /// for every text change to keep markers in sync.
  void shiftAnchors(int editPos, int removed, int inserted) {
    if (_annotations.isEmpty) return;
    final delta = inserted - removed;
    if (delta == 0 && removed == 0) return;
    var changed = false;
    final next = <EditorAnnotation>[];
    for (final a in _annotations) {
      if (a.orphaned) {
        next.add(a);
        continue;
      }
      final start = a.anchorStart;
      final end = a.anchorEnd;
      // Edit fully after the anchor — no change.
      if (editPos >= end) {
        next.add(a);
        continue;
      }
      // Edit fully before the anchor — slide it.
      if (editPos + removed <= start) {
        next.add(a.copyWith(anchorStart: start + delta));
        changed = true;
        continue;
      }
      // Edit overlaps the anchor — try to keep it but shrink/grow.
      final overlapStart = max(editPos, start);
      final overlapEnd = min(editPos + removed, end);
      final overlapRemoved = max(0, overlapEnd - overlapStart);
      final newStart = editPos < start ? start + delta : start;
      final newLen = a.anchorLength - overlapRemoved;
      if (newLen <= 0) {
        next.add(a.copyWith(orphaned: true));
      } else {
        next.add(a.copyWith(anchorStart: newStart, anchorLength: newLen));
      }
      changed = true;
    }
    if (changed) {
      _annotations = next;
      // Don't await — UI can rebuild now; persistence is best-effort.
      _persist();
      notifyListeners();
    }
  }

  /// Re-anchor a single annotation against current text. Used on load to
  /// recover from offset drift; if the original anchored text can't be
  /// located, the annotation is marked `orphaned` and surfaced in the
  /// side panel under "Orphaned".
  EditorAnnotation _reconcileAnchor(EditorAnnotation a, String text) {
    final s = a.anchorStart;
    final l = a.anchorLength;
    if (s >= 0 && s + l <= text.length) {
      final slice = text.substring(s, s + l);
      if (slice == a.anchoredText) return a;
    }
    if (a.anchoredText.isEmpty) return a.copyWith(orphaned: true);
    final found = text.indexOf(a.anchoredText);
    if (found < 0) return a.copyWith(orphaned: true);
    return a.copyWith(
      anchorStart: found,
      anchorLength: a.anchoredText.length,
      orphaned: false,
    );
  }

  Future<void> _persist() async {
    final sid = _sectionId;
    if (sid == null) return;
    final encoded = _annotations.map((a) => a.encode()).toList();
    await _storage.saveAnnotationStringsForSection(sid, encoded);
  }

  String _newId() {
    final r = Random();
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = r.nextInt(1 << 32).toRadixString(36);
    return 'an_${ts}_$rand';
  }
}
