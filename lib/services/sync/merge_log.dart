import 'dart:convert';

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
class MergeLog {
  MergeLog({String boxName = 'sync_merge_log', this.maxEntries = 50})
      : _boxName = boxName;

  final String _boxName;
  final int maxEntries;
  static const String _key = 'entries_v1';
  Box? _box;

  Future<void> init() async {
    if (_box != null) return;
    _box = await Hive.openBox(_boxName);
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
  }

  Future<void> clear() async => _box?.delete(_key);

  Future<void> dispose() async {
    await _box?.close();
    _box = null;
  }
}
