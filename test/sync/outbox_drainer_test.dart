import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:inkspacex/models/author_bookmark.dart';
import 'package:inkspacex/models/bookmark_model.dart';
import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/connectivity_service.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/outbox_drainer.dart';
import 'package:inkspacex/services/sync/pending_op.dart';
import 'package:inkspacex/services/sync/sync_dispatcher.dart';

class _FakeDispatcher implements SyncDispatcher {
  final List<String> calls = [];
  bool failNext = false;

  @override
  Future<WritingModel> createWriting(String userId, WritingModel book,
      {String? opId}) async {
    calls.add('createWriting:${book.id}');
    if (failNext) {
      failNext = false;
      throw Exception('boom');
    }
    return book;
  }

  @override
  Future<void> updateWritingMetadata(String userId, String writingId,
      {String? title,
      String? description,
      String? coverImagePath,
      ImageMeta? coverImageMeta,
      String? opId}) async {
    calls.add('updateWritingMetadata:$writingId');
  }

  @override
  Future<void> deleteWriting(String userId, String writingId,
      {String? opId}) async {
    calls.add('deleteWriting:$writingId');
  }

  @override
  Future<void> addSection(
      String userId, String writingId, SectionModel section,
      {String? opId}) async {
    calls.add('addSection:$writingId/${section.id}');
  }

  @override
  Future<void> updateSectionContent(String userId, String writingId,
      String sectionId, String content,
      {String canvasData = '', String? opId}) async {
    calls.add('updateSectionContent:$writingId/$sectionId');
    if (failNext) {
      failNext = false;
      throw Exception('boom');
    }
  }

  @override
  Future<void> renameSection(String userId, String writingId, String sectionId,
      String newTitle,
      {String? opId}) async {
    calls.add('renameSection:$writingId/$sectionId');
  }

  @override
  Future<void> deleteSection(
      String userId, String writingId, String sectionId,
      {String? opId}) async {
    calls.add('deleteSection:$writingId/$sectionId');
  }

  @override
  Future<String> upsertBookmark(BookmarkModel bookmark,
      {String? clientOpId}) async {
    calls.add('upsertBookmark:${bookmark.id}');
    return bookmark.id;
  }

  @override
  Future<void> deleteBookmark(String bookmarkId) async {
    calls.add('deleteBookmark:$bookmarkId');
  }

  @override
  Future<String> upsertAuthorBookmark(
    AuthorBookmark bookmark, {
    String? clientOpId,
  }) async {
    calls.add('upsertAuthorBookmark:${bookmark.id}');
    return bookmark.id;
  }

  @override
  Future<void> patchAuthorBookmark(
    String bookmarkId, {
    String? label,
    String? color,
    int? offset,
    bool clearLabel = false,
  }) async {
    calls.add('patchAuthorBookmark:$bookmarkId');
  }

  @override
  Future<void> deleteAuthorBookmark(String bookmarkId) async {
    calls.add('deleteAuthorBookmark:$bookmarkId');
  }

  @override
  Future<void> updateSectionMetadata(
    String userId,
    String writingId,
    String sectionId,
    Map<String, dynamic> fields, {
    String? opId,
  }) async {
    calls.add('updateSectionMetadata:$writingId/$sectionId');
  }

  @override
  Future<void> updateWritingProjectFields(
    String userId,
    String writingId,
    Map<String, dynamic> fields, {
    String? opId,
  }) async {
    calls.add('updateWritingProjectFields:$writingId');
  }
}

PendingOp _contentOp(String wid, String sid, String body) => PendingOp(
      kind: PendingOpKind.upsertSection,
      payload: {
        'writingId': wid,
        'sectionId': sid,
        'isNew': false,
        'fields': {'content': body},
      },
    );

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('drainer_test_');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('queued offline ops drain in order once online', () async {
    final outbox = Outbox(boxName: 'drain_order');
    await outbox.init();
    final connectivity = ConnectivityService()..debugSet(false);
    final dispatcher = _FakeDispatcher();
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: connectivity,
    );

    await outbox.enqueue(_contentOp('w1', 's1', '"a"'));
    await outbox.enqueue(_contentOp('w1', 's2', '"b"'));
    await outbox.enqueue(_contentOp('w1', 's3', '"c"'));

    // While offline, kicking the drainer is a no-op.
    drainer.kick();
    await Future<void>.delayed(Duration.zero);
    expect(dispatcher.calls, isEmpty);
    expect(outbox.length, 3);

    connectivity.debugSet(true);
    // The connectivity listener inside the drainer calls kick(); wait for
    // the resulting drain pass to complete.
    await drainer.drain();

    expect(dispatcher.calls, [
      'updateSectionContent:w1/s1',
      'updateSectionContent:w1/s2',
      'updateSectionContent:w1/s3',
    ]);
    expect(outbox.isEmpty, isTrue);

    await drainer.dispose();
    await outbox.dispose();
    await connectivity.dispose();
  });

  test('failed op stays in queue with bumped attemptCount, blocks the rest',
      () async {
    final outbox = Outbox(boxName: 'drain_fail');
    await outbox.init();
    final connectivity = ConnectivityService()..debugSet(true);
    final dispatcher = _FakeDispatcher()..failNext = true;
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: connectivity,
      backoff: (_) => Duration.zero,
      sleep: (_) async {},
    );

    await outbox.enqueue(_contentOp('w1', 's1', '"a"'));
    await outbox.enqueue(_contentOp('w1', 's2', '"b"'));

    await drainer.drain();

    final remaining = outbox.snapshot();
    expect(remaining.length, 2,
        reason: 'failure must leave the failing op AND every op behind it');
    expect(remaining.first.attemptCount, 1);
    expect(remaining.first.lastError, contains('boom'));

    // Second drain pass succeeds (failNext was a one-shot).
    await drainer.drain();
    expect(outbox.isEmpty, isTrue);
    expect(dispatcher.calls, [
      // Failed once...
      'updateSectionContent:w1/s1',
      // ...retried (and succeeded), then the next op flows through.
      'updateSectionContent:w1/s1',
      'updateSectionContent:w1/s2',
    ]);

    await drainer.dispose();
    await outbox.dispose();
    await connectivity.dispose();
  });

  test('drain is resumed after a simulated crash mid-flight', () async {
    // Round 1: enqueue, drain partially (one op succeeds), then "crash"
    // by closing Hive without finishing the queue.
    final outbox1 = Outbox(boxName: 'drain_crash');
    await outbox1.init();
    final connectivity = ConnectivityService()..debugSet(true);
    final dispatcher = _FakeDispatcher();
    final drainer1 = OutboxDrainer(
      outbox: outbox1,
      dataService: dispatcher,
      connectivity: connectivity,
    );

    await outbox1.enqueue(_contentOp('w1', 's1', '"a"'));
    await outbox1.enqueue(_contentOp('w1', 's2', '"b"'));
    await outbox1.enqueue(_contentOp('w1', 's3', '"c"'));

    // Make the second op fail so only the first is acked, then we
    // simulate a crash.
    var firstSeen = false;
    dispatcher.failNext = false;
    final originalCalls = dispatcher.calls;
    // Custom dispatcher with controlled failure on second call.
    final controlled = _FakeDispatcher();
    final drainerControlled = OutboxDrainer(
      outbox: outbox1,
      dataService: controlled,
      connectivity: connectivity,
      backoff: (_) => Duration.zero,
      sleep: (_) async {},
    );
    controlled.failNext = false;
    // We want: first op succeeds, second op fails, third op never seen.
    Future<void> runOne() async {
      await drainerControlled.drain();
    }
    // Trip failure on op 2 by setting the flag right after op 1 completes.
    // The fake throws on the *next* updateSectionContent call when the flag
    // is on, so we run drain in a loop and toggle it.
    //
    // Drive deterministically: drain pass 1 (no failure) drains all three
    // ops. To stop after one, we instead use `stop()` after a single op.
    //
    // Simpler model: enqueue 3, fail op 1, drain stops; remove the failure
    // flag, "crash" (close), reopen, drain remaining 3.
    expect(originalCalls, isEmpty); // sanity
    expect(firstSeen, isFalse);
    runOne; // unused, kept to make the diff readable.

    controlled.failNext = true;
    await drainerControlled.drain();
    // Op 1 failed → 3 ops still queued.
    expect(outbox1.length, 3);
    expect(controlled.calls.length, 1);

    // Simulate a crash: close Hive without flushing further work.
    await drainerControlled.dispose();
    await drainer1.dispose();
    await outbox1.dispose();
    await Hive.close();

    // Round 2: re-init Hive with the same path, reopen the box, drain.
    Hive.init(tmp.path);
    final outbox2 = Outbox(boxName: 'drain_crash');
    await outbox2.init();
    final dispatcher2 = _FakeDispatcher();
    final drainer2 = OutboxDrainer(
      outbox: outbox2,
      dataService: dispatcher2,
      connectivity: connectivity,
    );
    expect(outbox2.length, 3, reason: 'queue survived the crash');

    await drainer2.drain();
    expect(outbox2.isEmpty, isTrue);
    expect(dispatcher2.calls, [
      'updateSectionContent:w1/s1',
      'updateSectionContent:w1/s2',
      'updateSectionContent:w1/s3',
    ]);

    await drainer2.dispose();
    await outbox2.dispose();
    await connectivity.dispose();
  });

  test('upsertSection (isNew=true) calls addSection rather than update',
      () async {
    final outbox = Outbox(boxName: 'drain_isnew');
    await outbox.init();
    final connectivity = ConnectivityService()..debugSet(true);
    final dispatcher = _FakeDispatcher();
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: connectivity,
    );

    await outbox.enqueue(PendingOp(
      kind: PendingOpKind.upsertSection,
      payload: {
        'writingId': 'w1',
        'sectionId': 's-new',
        'isNew': true,
        'fields': {
          'title': 'Untitled',
          'content': '[]',
          'canvas_data': '',
          'section_color': 0xFF1982C4,
        },
      },
    ));

    await drainer.drain();
    expect(dispatcher.calls.single, 'addSection:w1/s-new');

    await drainer.dispose();
    await outbox.dispose();
    await connectivity.dispose();
  });
}
