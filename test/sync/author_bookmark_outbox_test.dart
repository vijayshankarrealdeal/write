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

/// A real ConnectivityService set to always-online via `debugSet`. We
/// don't call `init()` — that would touch the platform channel — but
/// `debugSet(true)` is enough to make `isOnlineNow` return true.
ConnectivityService _alwaysOnline() {
  final svc = ConnectivityService();
  svc.debugSet(true);
  return svc;
}

class _CapturingDispatcher implements SyncDispatcher {
  final List<({String method, Map<String, dynamic> payload})> calls = [];
  String fakeServerId = '';

  @override
  Future<String> upsertAuthorBookmark(
    AuthorBookmark bookmark, {
    String? clientOpId,
  }) async {
    calls.add((
      method: 'upsertAuthorBookmark',
      payload: {
        'id': bookmark.id,
        'writing_id': bookmark.writingId,
        'section_id': bookmark.sectionId,
        'offset': bookmark.offset,
        'label': bookmark.label,
        'color': bookmark.color,
        'client_op_id': clientOpId,
      },
    ));
    return fakeServerId.isEmpty ? bookmark.id : fakeServerId;
  }

  @override
  Future<void> patchAuthorBookmark(
    String bookmarkId, {
    String? label,
    String? color,
    int? offset,
    bool clearLabel = false,
  }) async {
    calls.add((
      method: 'patchAuthorBookmark',
      payload: {
        'id': bookmarkId,
        'label': label,
        'color': color,
        'offset': offset,
        'clearLabel': clearLabel,
      },
    ));
  }

  @override
  Future<void> deleteAuthorBookmark(String bookmarkId) async {
    calls.add((
      method: 'deleteAuthorBookmark',
      payload: {'id': bookmarkId},
    ));
  }

  // ----- The rest of the SyncDispatcher surface is irrelevant for these
  // tests. Throw if exercised — that's a sign a wrong op kind got
  // routed through the drainer.

  @override
  Future<WritingModel> createWriting(
    String userId,
    WritingModel book, {
    String? opId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> updateWritingMetadata(
    String userId,
    String writingId, {
    String? title,
    String? description,
    String? coverImagePath,
    ImageMeta? coverImageMeta,
    String? opId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> deleteWriting(String userId, String writingId, {String? opId}) =>
      throw UnimplementedError();

  @override
  Future<void> addSection(
    String userId,
    String writingId,
    SectionModel section, {
    String? opId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> updateSectionContent(
    String userId,
    String writingId,
    String sectionId,
    String content, {
    String canvasData = '',
    String? opId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> renameSection(
    String userId,
    String writingId,
    String sectionId,
    String newTitle, {
    String? opId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> deleteSection(
    String userId,
    String writingId,
    String sectionId, {
    String? opId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> updateSectionMetadata(
    String userId,
    String writingId,
    String sectionId,
    Map<String, dynamic> fields, {
    String? opId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> updateWritingProjectFields(
    String userId,
    String writingId,
    Map<String, dynamic> fields, {
    String? opId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<String> upsertBookmark(BookmarkModel bookmark,
          {String? clientOpId}) async =>
      throw UnimplementedError();

  @override
  Future<void> deleteBookmark(String bookmarkId) async =>
      throw UnimplementedError();
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('author_bookmark_outbox_');
    Hive.init(tmp.path);
  });
  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('drainer dispatches upsertAuthorBookmark and removes the op',
      () async {
    final outbox = Outbox(boxName: 'tb_ab_create');
    await outbox.init();
    final dispatcher = _CapturingDispatcher();
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: _alwaysOnline(),
    );

    final op = PendingOp(
      kind: PendingOpKind.upsertAuthorBookmark,
      payload: {
        'bookmarkId': 'local-1',
        'fields': {
          'writing_id': 'w1',
          'section_id': 's1',
          'offset': 17,
          'label': 'Daisy',
          'color': '#FFB300',
        },
      },
    );
    await outbox.enqueue(op);

    await drainer.drain();

    expect(outbox.length, 0);
    expect(dispatcher.calls.length, 1);
    final call = dispatcher.calls.single;
    expect(call.method, 'upsertAuthorBookmark');
    expect(call.payload['section_id'], 's1');
    expect(call.payload['offset'], 17);
    expect(call.payload['label'], 'Daisy');
    expect(call.payload['client_op_id'], op.id);

    await drainer.dispose();
    await outbox.dispose();
  });

  test('drainer remaps server id across queued patch ops', () async {
    final outbox = Outbox(boxName: 'tb_ab_remap');
    await outbox.init();
    final dispatcher = _CapturingDispatcher()..fakeServerId = 'server-99';
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: _alwaysOnline(),
    );

    // 1) upsert with local id
    final upsertOp = PendingOp(
      kind: PendingOpKind.upsertAuthorBookmark,
      payload: {
        'bookmarkId': 'local-1',
        'fields': {
          'writing_id': 'w',
          'section_id': 's',
          'offset': 0,
          'color': '#FFB300',
        },
      },
    );
    await outbox.enqueue(upsertOp);
    // 2) follow-up patch using the local id — drainer should rewrite
    //    this to use server-99 after the upsert acks.
    final patchOp = PendingOp(
      kind: PendingOpKind.patchAuthorBookmark,
      payload: {
        'bookmarkId': 'local-1',
        'fields': {'offset': 50},
      },
    );
    await outbox.enqueue(patchOp);

    await drainer.drain();

    expect(outbox.length, 0);
    expect(dispatcher.calls.length, 2);
    expect(dispatcher.calls[0].method, 'upsertAuthorBookmark');
    expect(dispatcher.calls[1].method, 'patchAuthorBookmark');
    // The patch ran against the remapped server id, not the local one.
    expect(dispatcher.calls[1].payload['id'], 'server-99');
    expect(dispatcher.calls[1].payload['offset'], 50);

    await drainer.dispose();
    await outbox.dispose();
  });

  test('drainer dispatches deleteAuthorBookmark', () async {
    final outbox = Outbox(boxName: 'tb_ab_delete');
    await outbox.init();
    final dispatcher = _CapturingDispatcher();
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: _alwaysOnline(),
    );

    await outbox.enqueue(PendingOp(
      kind: PendingOpKind.deleteAuthorBookmark,
      payload: {'bookmarkId': 'server-1'},
    ));

    await drainer.drain();

    expect(outbox.length, 0);
    expect(dispatcher.calls.single.method, 'deleteAuthorBookmark');
    expect(dispatcher.calls.single.payload['id'], 'server-1');

    await drainer.dispose();
    await outbox.dispose();
  });
}
