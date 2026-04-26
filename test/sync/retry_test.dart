import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:inkspacex/models/bookmark_model.dart';
import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/connectivity_service.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/outbox_drainer.dart';
import 'package:inkspacex/services/sync/pending_op.dart';
import 'package:inkspacex/services/sync/sync_dispatcher.dart';

/// Throws a sequence of pre-seeded errors before letting a call succeed.
class _ScriptedDispatcher implements SyncDispatcher {
  _ScriptedDispatcher(this._errors);

  final List<Object?> _errors; // null = success
  int _index = 0;

  int get attemptIndex => _index;

  void _maybeThrow() {
    if (_index >= _errors.length) return;
    final err = _errors[_index++];
    if (err != null) throw err;
  }

  @override
  Future<void> updateSectionContent(String userId, String writingId,
      String sectionId, String content,
      {String canvasData = ''}) async {
    _maybeThrow();
  }

  // The rest of the SyncDispatcher surface isn't exercised by these tests
  // — we throw to make accidental call-sites obvious.
  @override
  Future<WritingModel> createWriting(String userId, WritingModel book) =>
      throw UnimplementedError();
  @override
  Future<void> updateWritingMetadata(String userId, String writingId,
          {String? title,
          String? description,
          String? coverImagePath,
          ImageMeta? coverImageMeta}) =>
      throw UnimplementedError();
  @override
  Future<void> deleteWriting(String userId, String writingId) =>
      throw UnimplementedError();
  @override
  Future<void> addSection(
          String userId, String writingId, SectionModel section) =>
      throw UnimplementedError();
  @override
  Future<void> renameSection(
          String userId, String writingId, String sectionId, String newTitle) =>
      throw UnimplementedError();
  @override
  Future<void> deleteSection(
          String userId, String writingId, String sectionId) =>
      throw UnimplementedError();
  @override
  Future<String> upsertBookmark(BookmarkModel bookmark,
          {String? clientOpId}) =>
      throw UnimplementedError();
  @override
  Future<void> deleteBookmark(String bookmarkId) =>
      throw UnimplementedError();
}

ApiException _http500() => ApiException(
      statusCode: 500,
      message: 'boom',
      type: ApiErrorType.badResponse,
    );

ApiException _http403() => ApiException(
      statusCode: 403,
      message: 'forbidden',
      type: ApiErrorType.badResponse,
    );

PendingOp _contentOp() => PendingOp(
      kind: PendingOpKind.upsertSection,
      payload: {
        'writingId': 'w1',
        'sectionId': 's1',
        'isNew': false,
        'fields': {'content': '"hi"'},
      },
    );

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('retry_test_');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('5xx three times then 200 → eventual success with correct backoff',
      () async {
    final outbox = Outbox(boxName: 'retry_5xx');
    await outbox.init();
    final connectivity = ConnectivityService()..debugSet(true);
    final dispatcher = _ScriptedDispatcher([
      _http500(),
      _http500(),
      _http500(),
      null, // success
    ]);
    final backoffSchedule = <int>[];
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: connectivity,
      backoff: (attempt) {
        backoffSchedule.add(attempt);
        // Use a synthetic minute-resolution curve so we can assert the
        // 2^n shape without waiting on real time.
        final base = (1 << attempt) * 1000;
        return Duration(milliseconds: base > 60000 ? 60000 : base);
      },
      sleep: (_) async {}, // collapse all waits
    );

    await outbox.enqueue(_contentOp());

    // Drive the drainer four times: three failures, then success.
    for (var i = 0; i < 4; i++) {
      await drainer.drain();
      // Manually clear the cooldown that backoff just set, so the next
      // drain pass actually attempts the op (we're testing the schedule
      // shape, not the wall-clock wait).
      final ops = outbox.snapshot();
      if (ops.isNotEmpty) {
        await outbox.update(ops.first.copyWith(clearNextAttempt: true));
      }
    }

    expect(outbox.isEmpty, isTrue,
        reason: 'op should be acked after the 4th call returned 200');
    expect(dispatcher.attemptIndex, 4);
    // Backoff was computed for attempts 1, 2, 3 (after each failure).
    expect(backoffSchedule, [1, 2, 3]);

    await drainer.dispose();
    await outbox.dispose();
    await connectivity.dispose();
  });

  test('attempt cap: 10 transient failures flips the op to failed=true',
      () async {
    final outbox = Outbox(boxName: 'retry_cap');
    await outbox.init();
    final connectivity = ConnectivityService()..debugSet(true);
    final dispatcher = _ScriptedDispatcher(List.filled(20, _http500()));
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: connectivity,
      maxAttempts: 10,
      backoff: (_) => Duration.zero,
      sleep: (_) async {},
    );

    await outbox.enqueue(_contentOp());
    for (var i = 0; i < 10; i++) {
      await drainer.drain();
      final ops = outbox.snapshot();
      if (ops.isNotEmpty && !ops.first.failed) {
        await outbox.update(ops.first.copyWith(clearNextAttempt: true));
      }
    }

    final survivor = outbox.snapshot().single;
    expect(survivor.failed, isTrue);
    expect(survivor.attemptCount, 10);
    expect(drainer.snapshotFailed().single.id, survivor.id);
    expect(drainer.failedCount.value, 1);

    // Subsequent drain passes are no-ops; failed ops aren't retried.
    final before = dispatcher.attemptIndex;
    await drainer.drain();
    expect(dispatcher.attemptIndex, before);

    await drainer.dispose();
    await outbox.dispose();
    await connectivity.dispose();
  });

  test('non-retryable 4xx flips to failed=true on the first failure',
      () async {
    final outbox = Outbox(boxName: 'retry_4xx');
    await outbox.init();
    final connectivity = ConnectivityService()..debugSet(true);
    final dispatcher = _ScriptedDispatcher([_http403()]);
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: connectivity,
      backoff: (_) => Duration.zero,
      sleep: (_) async {},
    );

    await outbox.enqueue(_contentOp());
    await drainer.drain();

    final survivor = outbox.snapshot().single;
    expect(survivor.failed, isTrue,
        reason: '403 is not transient — must not retry');
    expect(survivor.attemptCount, 1);

    await drainer.dispose();
    await outbox.dispose();
    await connectivity.dispose();
  });

  test('retryFailedOp clears the failed flag and re-runs the op', () async {
    final outbox = Outbox(boxName: 'retry_manual');
    await outbox.init();
    final connectivity = ConnectivityService()..debugSet(true);
    final dispatcher = _ScriptedDispatcher([_http403(), null]);
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: connectivity,
      backoff: (_) => Duration.zero,
      sleep: (_) async {},
    );

    await outbox.enqueue(_contentOp());
    await drainer.drain();
    final failed = drainer.snapshotFailed().single;

    await drainer.retryFailedOp(failed.id);
    await drainer.drain();
    expect(outbox.isEmpty, isTrue);
    expect(drainer.failedCount.value, 0);

    await drainer.dispose();
    await outbox.dispose();
    await connectivity.dispose();
  });
}
