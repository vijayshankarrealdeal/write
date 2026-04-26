import 'dart:async';

import 'package:flutter/material.dart' show Color;
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/services/connectivity_service.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/pending_op.dart';
import 'package:inkspacex/services/sync/sync_dispatcher.dart';

/// Emitted when the drainer learns the server-side id for a locally-created
/// resource. The owner of the data model (currently EditorProvider) listens
/// and rewrites in-memory + on-disk references so subsequent mutations
/// target the canonical server id.
class IdRemapEvent {
  IdRemapEvent.writing({required this.localId, required this.serverId})
      : isWriting = true,
        writingId = null;
  IdRemapEvent.section({
    required this.localId,
    required this.serverId,
    required this.writingId,
  }) : isWriting = false;

  final String localId;
  final String serverId;
  final bool isWriting;
  final String? writingId;
}

/// Worker that drains the [Outbox], one op at a time, in queue order.
///
/// Invariants:
/// - Only one drain pass runs at a time (a second `kick()` while a pass is
///   in-flight is a no-op; the in-flight pass will see new ops as it loops).
/// - On success, the op is removed from the outbox. On failure, the op
///   is left in place and `attemptCount` is incremented; the caller
///   decides when to retry (Phase 3 adds backoff & cap).
/// - The drainer never advances past a failing op — head-of-line
///   blocking is intentional, because subsequent ops may depend on the
///   id remap performed by an earlier upsert.
class OutboxDrainer {
  OutboxDrainer({
    required Outbox outbox,
    required SyncDispatcher dataService,
    required ConnectivityService connectivity,
  })  : _outbox = outbox,
        _dataService = dataService,
        _connectivity = connectivity {
    _connectivitySub = _connectivity.onChange.listen((online) {
      if (online) kick();
    });
  }

  final Outbox _outbox;
  final SyncDispatcher _dataService;
  final ConnectivityService _connectivity;
  StreamSubscription<bool>? _connectivitySub;

  bool _draining = false;
  bool _stopRequested = false;

  final StreamController<IdRemapEvent> _remapController =
      StreamController<IdRemapEvent>.broadcast();
  final StreamController<PendingOp> _ackController =
      StreamController<PendingOp>.broadcast();

  /// Stream of id remap events. Subscribe before calling [drain] if you
  /// want to react to local→server id transitions (e.g. update model.id).
  Stream<IdRemapEvent> get onRemap => _remapController.stream;

  /// Stream of acknowledged ops (after the server confirmed). Useful for
  /// flipping local "synced" flags without polling the queue.
  Stream<PendingOp> get onAck => _ackController.stream;

  /// Schedule a drain pass. Cheap to call repeatedly.
  void kick() {
    if (!_connectivity.isOnlineNow) return;
    if (_draining) return;
    unawaited(drain());
  }

  /// Run the queue to completion (or first failure). Public so tests
  /// can drive it deterministically; production code should prefer [kick].
  Future<void> drain() async {
    if (_draining) return;
    _draining = true;
    _stopRequested = false;
    try {
      while (!_stopRequested) {
        final ops = _outbox.snapshot();
        if (ops.isEmpty) break;
        if (!_connectivity.isOnlineNow) break;
        final op = ops.first;
        final ok = await _processOne(op);
        if (!ok) break;
      }
    } finally {
      _draining = false;
    }
  }

  /// Cooperative stop — finishes the current op (if any) then exits.
  void stop() => _stopRequested = true;

  Future<bool> _processOne(PendingOp op) async {
    try {
      switch (op.kind) {
        case PendingOpKind.upsertWriting:
          await _dispatchUpsertWriting(op);
          break;
        case PendingOpKind.deleteWriting:
          await _dispatchDeleteWriting(op);
          break;
        case PendingOpKind.upsertSection:
          await _dispatchUpsertSection(op);
          break;
        case PendingOpKind.deleteSection:
          await _dispatchDeleteSection(op);
          break;
      }
      await _outbox.remove(op.id);
      _ackController.add(op);
      return true;
    } catch (e, st) {
      log.w('[outbox] op ${op.id} (${op.kind.name}) failed: $e');
      log.d('[outbox] stack: $st');
      await _outbox.update(op.copyWith(
        attemptCount: op.attemptCount + 1,
        lastError: e.toString(),
      ));
      return false;
    }
  }

  Future<void> _dispatchUpsertWriting(PendingOp op) async {
    final p = op.payload;
    final isNew = p['isNew'] == true;
    final fields = Map<String, dynamic>.from(p['fields'] as Map);
    final writingId = p['writingId'] as String;

    if (isNew) {
      // Reconstruct a minimal WritingModel for createWriting; sections are
      // always pushed via separate upsertSection ops, so we send an empty
      // sections list here and let those ops land independently.
      final book = WritingModel(
        id: writingId,
        title: fields['title'] as String? ?? '',
        author: fields['author'] as String? ?? '',
        description: fields['description'] as String? ?? '',
        coverImagePath: fields['coverImagePath'] as String? ?? '',
        writingType: WritingType
            .values[(fields['writingType'] as num?)?.toInt() ?? 0],
        subtype: fields['subtype'] as String? ?? '',
        sections: const <SectionModel>[],
      );
      final result = await _dataService.createWriting('', book);
      if (result.id != writingId) {
        await _propagateWritingRemap(writingId, result.id);
      }
    } else {
      await _dataService.updateWritingMetadata(
        '',
        writingId,
        title: fields['title'] as String?,
        description: fields['description'] as String?,
        coverImagePath: fields['coverImagePath'] as String?,
      );
    }
  }

  Future<void> _dispatchDeleteWriting(PendingOp op) async {
    await _dataService.deleteWriting('', op.payload['writingId'] as String);
  }

  Future<void> _dispatchUpsertSection(PendingOp op) async {
    final p = op.payload;
    final isNew = p['isNew'] == true;
    final writingId = p['writingId'] as String;
    final sectionId = p['sectionId'] as String;
    final fields = Map<String, dynamic>.from(p['fields'] as Map);

    if (isNew) {
      final section = SectionModel(
        id: sectionId,
        title: fields['title'] as String? ?? '',
        content: fields['content'] as String? ?? '',
        canvasData: fields['canvas_data'] as String? ?? '',
        sectionColor:
            Color((fields['section_color'] as num?)?.toInt() ?? 0xFF1982C4),
      );
      await _dataService.addSection('', writingId, section);
      if (section.id != sectionId) {
        await _propagateSectionRemap(writingId, sectionId, section.id);
      }
    } else {
      // Three sub-cases on the same endpoint: rename (title only),
      // content+canvas update, or both. The current API exposes them as
      // separate methods for the rename path and a single combined call
      // for content; we route by which fields are present.
      final hasTitle = fields.containsKey('title');
      final hasContent = fields.containsKey('content') ||
          fields.containsKey('canvas_data');
      if (hasTitle && !hasContent) {
        await _dataService.renameSection(
          '',
          writingId,
          sectionId,
          fields['title'] as String,
        );
      } else if (hasContent) {
        await _dataService.updateSectionContent(
          '',
          writingId,
          sectionId,
          fields['content'] as String? ?? '',
          canvasData: fields['canvas_data'] as String? ?? '',
        );
      }
    }
  }

  Future<void> _dispatchDeleteSection(PendingOp op) async {
    await _dataService.deleteSection(
      '',
      op.payload['writingId'] as String,
      op.payload['sectionId'] as String,
    );
  }

  Future<void> _propagateWritingRemap(String localId, String serverId) async {
    await _outbox.rewriteAll((op) {
      final p = op.payload;
      if (p['writingId'] == localId) {
        return op.copyWith(payload: {...p, 'writingId': serverId});
      }
      return op;
    });
    _remapController.add(IdRemapEvent.writing(
      localId: localId,
      serverId: serverId,
    ));
  }

  Future<void> _propagateSectionRemap(
      String writingId, String localId, String serverId) async {
    await _outbox.rewriteAll((op) {
      final p = op.payload;
      if (p['sectionId'] == localId && p['writingId'] == writingId) {
        return op.copyWith(payload: {...p, 'sectionId': serverId});
      }
      return op;
    });
    _remapController.add(IdRemapEvent.section(
      localId: localId,
      serverId: serverId,
      writingId: writingId,
    ));
  }

  Future<void> dispose() async {
    stop();
    await _connectivitySub?.cancel();
    await _remapController.close();
    await _ackController.close();
  }
}
