import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// One observed merge decision in [_mergeSections]. Captured for the
/// debug UI; intentionally lossy — full doc bodies are summarized via
/// length so the log doesn't balloon.
class MergeLogEntry {
  MergeLogEntry({
    required this.sectionId,
    required this.localUpdatedAt,
    required this.remoteUpdatedAt,
    required this.localLen,
    required this.remoteLen,
    required this.winner,
    DateTime? observedAt,
  }) : observedAt = observedAt ?? DateTime.now();

  final String sectionId;
  final DateTime localUpdatedAt;
  final DateTime remoteUpdatedAt;
  final int localLen;
  final int remoteLen;

  /// 'local' or 'remote' — whichever side the merge function chose.
  final String winner;
  final DateTime observedAt;

  Map<String, dynamic> toJson() => {
        'sectionId': sectionId,
        'localUpdatedAt': localUpdatedAt.toIso8601String(),
        'remoteUpdatedAt': remoteUpdatedAt.toIso8601String(),
        'localLen': localLen,
        'remoteLen': remoteLen,
        'winner': winner,
        'observedAt': observedAt.toIso8601String(),
      };

  factory MergeLogEntry.fromJson(Map<String, dynamic> json) => MergeLogEntry(
        sectionId: json['sectionId'] as String,
        localUpdatedAt: DateTime.parse(json['localUpdatedAt'] as String),
        remoteUpdatedAt: DateTime.parse(json['remoteUpdatedAt'] as String),
        localLen: (json['localLen'] as num).toInt(),
        remoteLen: (json['remoteLen'] as num).toInt(),
        winner: json['winner'] as String,
        observedAt: DateTime.parse(json['observedAt'] as String),
      );
}

/// Bounded ring buffer of merge events, persisted to its own Hive box.
///
/// Keeps only the most recent [maxEntries] (default 50) so the box can't
/// grow unboundedly. Reads are O(N) but N is small by construction; a
/// proper time-ordered store isn't justified for a debug-only feature.
///
/// Also exposes a [latestEntry] [ValueListenable] and a [conflicts]
/// stream so the UI can surface a "your edit was merged" toast the
/// moment a conflict is observed — no polling, no debug-only scope.
class MergeLog {
  MergeLog({String boxName = 'sync_merge_log', this.maxEntries = 50})
      : _boxName = boxName;

  final String _boxName;
  final int maxEntries;
  static const String _key = 'entries_v1';
  Box? _box;
  final ValueNotifier<MergeLogEntry?> _latest =
      ValueNotifier<MergeLogEntry?>(null);
  final StreamController<MergeLogEntry> _conflictController =
      StreamController<MergeLogEntry>.broadcast();

  /// Latest recorded merge event (or null if none yet). UI can listen
  /// directly via [ValueListenableBuilder].
  ValueListenable<MergeLogEntry?> get latestEntry => _latest;

  /// Broadcast stream that fires once per recorded merge entry where
  /// the *remote* side won — that's the case where a user's local edit
  /// was overwritten and they deserve to know.
  Stream<MergeLogEntry> get conflicts => _conflictController.stream;

  Future<void> init() async {
    if (_box != null) return;
    _box = await Hive.openBox(_boxName);
    final existing = snapshot();
    if (existing.isNotEmpty) {
      _latest.value = existing.last;
    }
  }

  List<MergeLogEntry> snapshot() {
    final raw = _box?.get(_key);
    if (raw is! String) return <MergeLogEntry>[];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) =>
              MergeLogEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return <MergeLogEntry>[];
    }
  }

  Future<void> record(MergeLogEntry entry) async {
    final entries = snapshot()..add(entry);
    if (entries.length > maxEntries) {
      entries.removeRange(0, entries.length - maxEntries);
    }
    await _box?.put(
      _key,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
    _latest.value = entry;
    // Only surface user-visible toasts when the *remote* side won —
    // otherwise we'd flash a banner every time a sync round-trip
    // confirms our own edit, which would be noise.
    if (entry.winner == 'remote' && !_conflictController.isClosed) {
      _conflictController.add(entry);
    }
  }

  Future<void> clear() async {
    await _box?.delete(_key);
    _latest.value = null;
  }

  Future<void> dispose() async {
    await _conflictController.close();
    await _box?.close();
    _box = null;
  }
}
