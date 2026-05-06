import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart' show Color;
import 'package:inkspacex/models/bookmark_model.dart';
import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/api/api_client.dart' show ApiException, ApiErrorType;
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/services/connectivity_service.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/pending_op.dart';
import 'package:inkspacex/services/sync/sync_dispatcher.dart';

/// Emitted when the drainer learns the server-side id for a locally-created
/// resource. The owner of the data model (currently EditorProvider) listens
/// and rewrites in-memory + on-disk references so subsequent mutations
/// target the canonical server id.
///
/// `kind` distinguishes writing vs. section vs. bookmark remaps so a
/// listener can target the right model without a switch on `isWriting`.
class IdRemapEvent {
  IdRemapEvent.writing({required this.localId, required this.serverId})
      : kind = IdRemapKind.writing,
        writingId = null;
  IdRemapEvent.section({
    required this.localId,
    required this.serverId,
    required this.writingId,
  }) : kind = IdRemapKind.section;
  IdRemapEvent.bookmark({required this.localId, required this.serverId})
      : kind = IdRemapKind.bookmark,
        writingId = null;

  final String localId;
  final String serverId;
  final IdRemapKind kind;
  final String? writingId;

  bool get isWriting => kind == IdRemapKind.writing;
}

enum IdRemapKind { writing, section, bookmark }

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
    int maxAttempts = 10,
    Duration Function(int attempt)? backoff,
    Future<void> Function(Duration)? sleep,
    math.Random? random,
  })  : _outbox = outbox,
        _dataService = dataService,
        _connectivity = connectivity,
        _maxAttempts = maxAttempts,
        _backoff = backoff ?? _defaultBackoff,
        _sleep = sleep ?? Future.delayed,
        _random = random ?? math.Random() {
    _connectivitySub = _connectivity.onChange.listen((online) {
      if (online) kick();
    });
  }

  /// `min(2^n * 1s, 60s)` per the Phase 3 spec. Jitter is applied
  /// separately in [_processOne] so deterministic tests can override the
  /// backoff curve without losing the jitter contract.
  static Duration _defaultBackoff(int attempt) {
    final base = math.min(60000, (1 << attempt) * 1000);
    return Duration(milliseconds: base);
  }

  final Outbox _outbox;
  final SyncDispatcher _dataService;
  final ConnectivityService _connectivity;
  final int _maxAttempts;
  final Duration Function(int attempt) _backoff;
  final Future<void> Function(Duration) _sleep;
  final math.Random _random;
  StreamSubscription<bool>? _connectivitySub;
  Timer? _retryTimer;

  bool _stopRequested = false;
  Future<void>? _inFlight;
  bool get _draining => _inFlight != null;

  /// Failure-count notifier so the UI can surface "X failed ops" without
  /// polling the queue. Updated synchronously alongside outbox writes.
  final ValueNotifier<int> _failedCount = ValueNotifier<int>(0);
  ValueListenable<int> get failedCount => _failedCount;

  /// Number of ops in the queue that the drainer has given up on. Computed
  /// lazily — the drainer keeps the cached counter in sync after every
  /// success/failure.
  int _countFailed() =>
      _outbox.snapshot().where((o) => o.failed).length;

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

  /// Drop the failure flag and counters on a single op so the drainer
  /// re-tries it on the next kick. Used by the "Retry" affordance in the
  /// failed-ops bottom sheet.
  Future<void> retryFailedOp(String opId) async {
    final ops = _outbox.snapshot();
    final op = ops.firstWhere(
      (o) => o.id == opId,
      orElse: () => throw StateError('No queued op with id $opId'),
    );
    await _outbox.update(op.copyWith(
      failed: false,
      attemptCount: 0,
      clearLastError: true,
      clearNextAttempt: true,
    ));
    _failedCount.value = _countFailed();
    kick();
  }

  /// Drop a single failed op without sending it. Used by the "Discard"
  /// affordance in the failed-ops bottom sheet.
  Future<void> discardOp(String opId) async {
    await _outbox.remove(opId);
    _failedCount.value = _countFailed();
  }

  /// Run the queue to completion (or first failure). Public so tests
  /// can drive it deterministically; production code should prefer [kick].
  ///
  /// If a drain pass is already in-flight, returns the same Future so a
  /// caller can `await` for the queue to settle without spawning a second
  /// pass.
  Future<void> drain() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final completer = Completer<void>();
    _inFlight = completer.future;
    _runDrain().whenComplete(() {
      _inFlight = null;
      completer.complete();
    });
    return completer.future;
  }

  Future<void> _runDrain() async {
    _stopRequested = false;
    while (!_stopRequested) {
      final ops = _outbox.snapshot();
      if (ops.isEmpty) break;
      if (!_connectivity.isOnlineNow) break;
      final op = ops.first;
      if (op.failed) break; // user must retry/discard
      final scheduled = op.nextAttemptAt;
      if (scheduled != null && scheduled.isAfter(DateTime.now())) {
        _scheduleRetryAt(scheduled);
        break;
      }
      final ok = await _processOne(op);
      if (!ok) break;
    }
  }

  void _scheduleRetryAt(DateTime when) {
    _retryTimer?.cancel();
    final delay = when.difference(DateTime.now());
    if (delay.isNegative) {
      kick();
      return;
    }
    _retryTimer = Timer(delay, kick);
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
        case PendingOpKind.upsertBookmark:
          await _dispatchUpsertBookmark(op);
          break;
        case PendingOpKind.deleteBookmark:
          await _dispatchDeleteBookmark(op);
          break;
        case PendingOpKind.updateWritingProject:
          await _dispatchUpdateWritingProject(op);
          break;
      }
      await _outbox.remove(op.id);
      _failedCount.value = _countFailed();
      _ackController.add(op);
      return true;
    } catch (e, st) {
      log.w('[outbox] op ${op.id} (${op.kind.name}) failed: $e');
      log.d('[outbox] stack: $st');
      final nextAttempt = op.attemptCount + 1;
      final classification = _classify(e);
      switch (classification) {
        case _ErrorClass.transient:
          if (nextAttempt >= _maxAttempts) {
            await _outbox.update(op.copyWith(
              attemptCount: nextAttempt,
              lastError: e.toString(),
              failed: true,
              clearNextAttempt: true,
            ));
          } else {
            final delay = _withJitter(_backoff(nextAttempt));
            await _outbox.update(op.copyWith(
              attemptCount: nextAttempt,
              lastError: e.toString(),
              nextAttemptAt: DateTime.now().add(delay),
            ));
            _scheduleRetryAt(DateTime.now().add(delay));
            unawaited(_sleep(delay));
          }
          break;
        case _ErrorClass.permanent:
          // 4xx (other than 401, which the ApiClient already retried with
          // a refreshed token before reaching us) is not worth retrying.
          await _outbox.update(op.copyWith(
            attemptCount: nextAttempt,
            lastError: e.toString(),
            failed: true,
            clearNextAttempt: true,
          ));
          break;
      }
      _failedCount.value = _countFailed();
      return false;
    }
  }

  Duration _withJitter(Duration base) {
    // ±25% jitter — keeps a thundering herd from re-converging after a
    // shared outage.
    final ms = base.inMilliseconds;
    final jitter = (ms * 0.25 * (_random.nextDouble() * 2 - 1)).round();
    final result = ms + jitter;
    return Duration(milliseconds: result < 0 ? 0 : result);
  }

  _ErrorClass _classify(Object error) {
    if (error is ApiException) {
      switch (error.type) {
        case ApiErrorType.timeout:
        case ApiErrorType.connection:
          return _ErrorClass.transient;
        case ApiErrorType.badResponse:
          final code = error.statusCode ?? 0;
          if (code >= 500) return _ErrorClass.transient;
          if (code == 408 || code == 429) return _ErrorClass.transient;
          // 401 reaching here means refresh already failed once — still
          // transient (user may sign in again), but the spec says
          // "immediate retry" so let it fall back to fast retry through
          // the regular schedule (attempt 1 ≈ 2s).
          if (code == 401) return _ErrorClass.transient;
          return _ErrorClass.permanent;
        case ApiErrorType.unknown:
          return _ErrorClass.transient;
      }
    }
    // Unknown exception types: assume transient, the sender owes us a
    // better signal next time.
    return _ErrorClass.transient;
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
        coverImageMeta: ImageMeta.tryFromJson(fields['coverImageMeta']),
        writingType: WritingType
            .values[(fields['writingType'] as num?)?.toInt() ?? 0],
        subtype: fields['subtype'] as String? ?? '',
        sections: const <SectionModel>[],
      );
      final result = await _dataService.createWriting('', book, opId: op.id);
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
        coverImageMeta: ImageMeta.tryFromJson(fields['coverImageMeta']),
        opId: op.id,
      );
    }
  }

  Future<void> _dispatchDeleteWriting(PendingOp op) async {
    await _dataService.deleteWriting(
      '',
      op.payload['writingId'] as String,
      opId: op.id,
    );
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
        parentId: fields['parent_id'] as String?,
        order: (fields['sort_order'] as num?)?.toInt() ?? 0,
        kind: SectionKindCodec.fromCode(fields['kind'] as String?),
        synopsis: fields['synopsis'] as String? ?? '',
        notes: fields['notes'] as String? ?? '',
        labelColor: (fields['label_color'] as num?)?.toInt(),
        keywords: (fields['keywords'] is List)
            ? (fields['keywords'] as List).whereType<String>().toList()
            : <String>[],
        includeInPublish: fields['include_in_publish'] is bool
            ? fields['include_in_publish'] as bool
            : true,
      );
      await _dataService.addSection('', writingId, section, opId: op.id);
      if (section.id != sectionId) {
        await _propagateSectionRemap(writingId, sectionId, section.id);
      }
    } else {
      // Title-only and content updates have dedicated endpoints; everything
      // else (parent/order/kind/synopsis/notes/label/keywords/publish-gate)
      // routes through the generic metadata patch.
      final hasTitle = fields.containsKey('title');
      final hasContent = fields.containsKey('content') ||
          fields.containsKey('canvas_data');
      final metadata = <String, dynamic>{};
      for (final key in const [
        'parent_id',
        'sort_order',
        'kind',
        'synopsis',
        'notes',
        'label_color',
        'keywords',
        'include_in_publish',
        'section_color',
      ]) {
        if (fields.containsKey(key)) metadata[key] = fields[key];
      }
      if (hasContent) {
        await _dataService.updateSectionContent(
          '',
          writingId,
          sectionId,
          fields['content'] as String? ?? '',
          canvasData: fields['canvas_data'] as String? ?? '',
          opId: op.id,
        );
      }
      if (hasTitle && !hasContent) {
        await _dataService.renameSection(
          '',
          writingId,
          sectionId,
          fields['title'] as String,
          opId: op.id,
        );
      } else if (hasTitle && hasContent) {
        // Title + content together — already updated content above; PUT
        // the title separately so the rename endpoint stays the canonical
        // path for echo-suppression headers.
        await _dataService.renameSection(
          '',
          writingId,
          sectionId,
          fields['title'] as String,
          opId: op.id,
        );
      }
      if (metadata.isNotEmpty) {
        await _dataService.updateSectionMetadata(
          '',
          writingId,
          sectionId,
          metadata,
          opId: op.id,
        );
      }
    }
  }

  Future<void> _dispatchUpdateWritingProject(PendingOp op) async {
    final writingId = op.payload['writingId'] as String;
    final fields = Map<String, dynamic>.from(op.payload['fields'] as Map);
    if (fields.isEmpty) return;
    await _dataService.updateWritingProjectFields(
      '',
      writingId,
      fields,
      opId: op.id,
    );
  }

  Future<void> _dispatchDeleteSection(PendingOp op) async {
    await _dataService.deleteSection(
      '',
      op.payload['writingId'] as String,
      op.payload['sectionId'] as String,
      opId: op.id,
    );
  }

  Future<void> _dispatchUpsertBookmark(PendingOp op) async {
    final p = op.payload;
    final localId = p['bookmarkId'] as String;
    final fields = Map<String, dynamic>.from(p['fields'] as Map);
    final anchor = Map<String, dynamic>.from(fields['anchor'] as Map);
    final bookmark = BookmarkModel(
      id: localId,
      feedItemId: fields['feed_item_id'] as String,
      sectionId: fields['section_id'] as String?,
      sectionIndex: (fields['section_index'] as num?)?.toInt() ?? 0,
      paragraphIdx: (anchor['paragraph_idx'] as num?)?.toInt() ?? 0,
      charOffset: (anchor['char_offset'] as num?)?.toInt() ?? 0,
      label: fields['label'] as String?,
      color: (fields['color'] as String?) ?? '#FFB300',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final serverId =
        await _dataService.upsertBookmark(bookmark, clientOpId: op.id);
    if (serverId.isNotEmpty && serverId != localId) {
      await _propagateBookmarkRemap(localId, serverId);
    }
  }

  Future<void> _dispatchDeleteBookmark(PendingOp op) async {
    await _dataService.deleteBookmark(op.payload['bookmarkId'] as String);
  }

  Future<void> _propagateBookmarkRemap(String localId, String serverId) async {
    await _outbox.rewriteAll((op) {
      final p = op.payload;
      if (p['bookmarkId'] == localId) {
        return op.copyWith(payload: {...p, 'bookmarkId': serverId});
      }
      return op;
    });
    _remapController.add(IdRemapEvent.bookmark(
      localId: localId,
      serverId: serverId,
    ));
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
    _retryTimer?.cancel();
    await _connectivitySub?.cancel();
    await _remapController.close();
    await _ackController.close();
    _failedCount.dispose();
  }

  /// Public, read-only snapshot of currently-failed ops, for the UI's
  /// "failed ops" sheet.
  List<PendingOp> snapshotFailed() =>
      _outbox.snapshot().where((o) => o.failed).toList();
}

enum _ErrorClass { transient, permanent }
