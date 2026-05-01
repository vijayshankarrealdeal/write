import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart'
    show ChangeSource, Document, QuillController;

import 'package:inkspacex/models/section_version_model.dart';
import 'package:inkspacex/services/storage_service.dart';

/// Per-section version history. Snapshots are taken on three triggers:
///   1. Idle — user has stopped typing for [_idleSnapshotDelay].
///   2. Session close — `flush()` is called from app pause / dispose.
///   3. Manual — `captureManual()` from the UI ("Save version" button).
///
/// Retention: the most recent [_maxAutoSnapshots] auto-snapshots are kept,
/// plus one daily snapshot for [_dailyRetentionDays] days. Manual
/// snapshots never expire. Restore is non-destructive — restoring a
/// version writes a new "before-restore" snapshot first so a user who
/// clicks restore by mistake can still get back.
class VersionHistoryProvider extends ChangeNotifier {
  VersionHistoryProvider(this._storage);

  final StorageService _storage;

  static const Duration _idleSnapshotDelay = Duration(seconds: 30);
  static const int _maxAutoSnapshots = 50;
  static const int _dailyRetentionDays = 30;

  String? _sectionId;
  List<SectionVersion> _versions = const [];
  Timer? _idleTimer;
  String? _lastSnapshotJson;

  String? get sectionId => _sectionId;
  List<SectionVersion> get versions => List.unmodifiable(_versions);

  void loadForSection(String sectionId) {
    _idleTimer?.cancel();
    _sectionId = sectionId;
    final raw = _storage.getVersionStringsForSection(sectionId);
    final loaded = <SectionVersion>[];
    for (final s in raw) {
      try {
        loaded.add(SectionVersion.decode(s));
      } catch (_) {
        // Drop unreadable entries — better than blocking the editor.
      }
    }
    loaded.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _versions = loaded;
    _lastSnapshotJson = loaded.isEmpty ? null : loaded.last.contentJson;
    notifyListeners();
  }

  void clear() {
    _idleTimer?.cancel();
    _sectionId = null;
    _versions = const [];
    _lastSnapshotJson = null;
    notifyListeners();
  }

  /// Schedule an auto-snapshot if the user goes idle. Call this on every
  /// document change. The timer resets each call, so the snapshot only
  /// fires once typing has stopped.
  void scheduleSnapshot(QuillController controller) {
    final sid = _sectionId;
    if (sid == null) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleSnapshotDelay, () {
      _capture(controller, manual: false, label: '');
    });
  }

  /// Force-flush an auto-snapshot now (e.g. on app pause / page close).
  /// No-op if the document hasn't changed since the last snapshot.
  void flush(QuillController controller) {
    _idleTimer?.cancel();
    _capture(controller, manual: false, label: '');
  }

  Future<SectionVersion?> captureManual(
    QuillController controller, {
    String label = '',
  }) async {
    return _capture(controller, manual: true, label: label);
  }

  /// Insert the version's content back into the controller. Before doing
  /// so we capture the *current* state as a manual snapshot so undo via
  /// the version list itself is always possible.
  Future<void> restore(
    SectionVersion version,
    QuillController controller,
  ) async {
    await _capture(
      controller,
      manual: true,
      label: 'Before restoring ${_shortStamp(version.createdAt)}',
    );
    final doc = _docFromJson(version.contentJson);
    if (doc == null) return;
    controller.document = doc;
    controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
  }

  Future<void> deleteVersion(String versionId) async {
    _versions = _versions.where((v) => v.id != versionId).toList();
    await _persist();
    notifyListeners();
  }

  // ── Internals ──

  Future<SectionVersion?> _capture(
    QuillController controller, {
    required bool manual,
    required String label,
  }) async {
    final sid = _sectionId;
    if (sid == null) return null;
    final json = jsonEncode(controller.document.toDelta().toJson());
    if (!manual && json == _lastSnapshotJson) {
      // Auto-snapshots: skip if nothing changed since the last capture.
      return null;
    }
    final wc = _wordCount(controller);
    final entry = SectionVersion(
      id: _newId(),
      sectionId: sid,
      contentJson: json,
      wordCount: wc,
      createdAt: DateTime.now(),
      label: label,
      manual: manual,
    );
    _versions = [..._versions, entry];
    _lastSnapshotJson = json;
    _prune();
    await _persist();
    notifyListeners();
    return entry;
  }

  void _prune() {
    // Always keep manual entries. From the auto entries, keep the most
    // recent _maxAutoSnapshots, plus one per day for _dailyRetentionDays.
    final manual = _versions.where((v) => v.manual).toList();
    final autos = _versions.where((v) => !v.manual).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (autos.length <= _maxAutoSnapshots) {
      return;
    }
    final recent = autos.sublist(autos.length - _maxAutoSnapshots);
    final older = autos.sublist(0, autos.length - _maxAutoSnapshots);
    final cutoff =
        DateTime.now().subtract(const Duration(days: _dailyRetentionDays));
    final perDay = <String, SectionVersion>{};
    for (final v in older) {
      if (v.createdAt.isBefore(cutoff)) continue;
      final key =
          '${v.createdAt.year}-${v.createdAt.month}-${v.createdAt.day}';
      // Keep the latest entry per day.
      final existing = perDay[key];
      if (existing == null || v.createdAt.isAfter(existing.createdAt)) {
        perDay[key] = v;
      }
    }
    final kept = [
      ...manual,
      ...recent,
      ...perDay.values,
    ];
    kept.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _versions = kept;
  }

  Future<void> _persist() async {
    final sid = _sectionId;
    if (sid == null) return;
    final encoded = _versions.map((v) => v.encode()).toList();
    await _storage.saveVersionStringsForSection(sid, encoded);
  }

  Document? _docFromJson(String json) {
    try {
      final list = jsonDecode(json);
      if (list is List) return Document.fromJson(list);
    } catch (_) {}
    return null;
  }

  int _wordCount(QuillController c) {
    final t = c.document.toPlainText().trim();
    if (t.isEmpty) return 0;
    return t.split(RegExp(r'\s+')).length;
  }

  String _newId() {
    final r = Random();
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = r.nextInt(0xFFFFFFFF).toRadixString(36);
    return 'v_${ts}_$rand';
  }

  String _shortStamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }
}
