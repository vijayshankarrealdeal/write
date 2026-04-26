import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:inkspacex/services/sync/pending_op.dart';

/// Append-only durable queue of [PendingOp]s, persisted in its own Hive box
/// (separate from the user's books blob — same crash on the books store
/// must not corrupt or wipe the queue, and vice versa).
///
/// The box is per-user: at boot the queue is closed (no user signed in),
/// and [switchUser] opens `sync_outbox_<uid>` after auth resolves. This
/// guarantees one user's queued ops can never be sent under another
/// user's auth token — the boxes are physically separate files.
///
/// All mutations rewrite the full list to the box for simplicity. The
/// expected steady-state size is "a handful" of ops; if it grows huge
/// the right answer is faster draining, not a smarter queue.
class Outbox {
  Outbox({String? boxName}) : _fixedBoxName = boxName;

  /// When non-null, this name is used unconditionally and [switchUser] is a
  /// no-op — useful for tests that drive the outbox directly without an
  /// auth flow.
  final String? _fixedBoxName;
  static const String _key = 'ops_v1';
  Box? _box;
  String? _currentUid;

  final ValueNotifier<int> _pendingCount = ValueNotifier<int>(0);

  /// Reactive op-count, suitable for status-chip widgets.
  ValueListenable<int> get pendingCount => _pendingCount;

  /// True once a user-scoped box is open and ready to enqueue/drain.
  bool get isOpen => _box != null;

  /// Initialise the durable queue. In production this is called once at
  /// app boot and is a no-op until [switchUser] is called with a real uid;
  /// in tests, when the outbox is constructed with an explicit `boxName`
  /// it opens that box immediately.
  Future<void> init() async {
    if (_fixedBoxName != null && _box == null) {
      _box = await Hive.openBox(_fixedBoxName);
      _pendingCount.value = _readAll().length;
    }
  }

  /// Open the per-user queue for [uid]. Pass `null` on logout to close the
  /// current box without touching its on-disk contents — pending ops sit
  /// dormant until the same user signs in again.
  Future<void> switchUser(String? uid) async {
    if (_fixedBoxName != null) return;
    if (_currentUid == uid && _box != null) return;
    if (_box != null) {
      await _box!.close();
      _box = null;
    }
    _currentUid = uid;
    if (uid == null) {
      _pendingCount.value = 0;
      return;
    }
    _box = await Hive.openBox('sync_outbox_$uid');
    _pendingCount.value = _readAll().length;
  }

  /// Snapshot current ops in order (oldest first).
  List<PendingOp> snapshot() => _readAll();

  bool get isEmpty => (_box?.isEmpty ?? true) || snapshot().isEmpty;
  int get length => snapshot().length;

  Future<void> enqueue(PendingOp op) async {
    final ops = _readAll()..add(op);
    await _writeAll(ops);
  }

  /// Replace an op in place (used by the drainer to bump `attemptCount`
  /// after a failed attempt). Looks the op up by id.
  Future<void> update(PendingOp op) async {
    final ops = _readAll();
    final idx = ops.indexWhere((o) => o.id == op.id);
    if (idx == -1) return;
    ops[idx] = op;
    await _writeAll(ops);
  }

  /// Drop an op from the queue by id (the drainer does this on success).
  Future<void> remove(String opId) async {
    final ops = _readAll()..removeWhere((o) => o.id == opId);
    await _writeAll(ops);
  }

  /// Apply [transform] to every op (used to rewrite local ids → server ids
  /// after an upsert succeeds). Persists the resulting list.
  Future<void> rewriteAll(PendingOp Function(PendingOp) transform) async {
    final ops = _readAll().map(transform).toList();
    await _writeAll(ops);
  }

  Future<void> clear() async {
    await _box?.delete(_key);
    _pendingCount.value = 0;
  }

  List<PendingOp> _readAll() {
    final raw = _box?.get(_key);
    if (raw is! String) return <PendingOp>[];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => PendingOp.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return <PendingOp>[];
    }
  }

  Future<void> _writeAll(List<PendingOp> ops) async {
    final box = _box;
    if (box == null) {
      throw StateError(
        'Outbox is closed (no user signed in). Call switchUser(uid) before '
        'enqueuing.',
      );
    }
    await box.put(_key, jsonEncode(ops.map((o) => o.toJson()).toList()));
    _pendingCount.value = ops.length;
  }

  Future<void> dispose() async {
    _pendingCount.dispose();
    await _box?.close();
    _box = null;
  }
}
