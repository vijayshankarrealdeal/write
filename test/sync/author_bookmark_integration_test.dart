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

/// In-memory "server" that mirrors the FastAPI router's behaviour so we
/// can roundtrip an op without standing up Postgres. Implements the
/// dedupe-on-(section_id, offset) rule and returns 200 vs. 201 by way
/// of a synthetic ``status`` field on each call.
class _FakeServer implements SyncDispatcher {
  final Map<String, AuthorBookmark> _store = {};
  final List<({String method, String? id, dynamic body})> log = [];
  // Maps the (section_id, offset) tuple used by the upsert dedupe key
  // to the row's id, so a replay returns the same id.
  final Map<String, String> _dedupe = {};
  int _idCounter = 0;

  String _newId() {
    _idCounter += 1;
    return 'srv-$_idCounter';
  }

  String _dedupeKey(String sectionId, int offset) => '$sectionId|$offset';

  @override
  Future<String> upsertAuthorBookmark(
    AuthorBookmark bookmark, {
    String? clientOpId,
  }) async {
    final key = _dedupeKey(bookmark.sectionId, bookmark.offset);
    final existingId = _dedupe[key];
    if (existingId != null) {
      // 200 OK — idempotent return.
      log.add((method: 'upsert(200)', id: existingId, body: bookmark.toCreateJson()));
      // Update mutable fields if changed.
      final existing = _store[existingId]!;
      _store[existingId] = existing.copyWith(
        label: bookmark.label ?? existing.label,
        color: bookmark.color,
      );
      return existingId;
    }
    final newId = _newId();
    _store[newId] = bookmark.copyWith(id: newId);
    _dedupe[key] = newId;
    log.add((method: 'upsert(201)', id: newId, body: bookmark.toCreateJson()));
    return newId;
  }

  @override
  Future<void> patchAuthorBookmark(
    String bookmarkId, {
    String? label,
    String? color,
    int? offset,
    bool clearLabel = false,
  }) async {
    final existing = _store[bookmarkId];
    if (existing == null) {
      log.add((method: 'patch(404)', id: bookmarkId, body: null));
      return;
    }
    if (offset != null && offset != existing.offset) {
      // Re-key in dedupe map.
      _dedupe.removeWhere((_, v) => v == bookmarkId);
      _dedupe[_dedupeKey(existing.sectionId, offset)] = bookmarkId;
    }
    _store[bookmarkId] = existing.copyWith(
      label: clearLabel ? null : (label ?? existing.label),
      color: color ?? existing.color,
      offset: offset ?? existing.offset,
      clearLabel: clearLabel,
    );
    log.add((method: 'patch(200)', id: bookmarkId, body: {
      'label': label,
      'color': color,
      'offset': offset,
      'clearLabel': clearLabel,
    }));
  }

  @override
  Future<void> deleteAuthorBookmark(String bookmarkId) async {
    final removed = _store.remove(bookmarkId);
    _dedupe.removeWhere((_, v) => v == bookmarkId);
    log.add((method: 'delete', id: bookmarkId, body: removed?.label));
  }

  // Unimplemented surface — these aren't exercised by the integration
  // test. Throwing makes any drift loud.
  @override
  Future<WritingModel> createWriting(String userId, WritingModel book,
          {String? opId}) =>
      throw UnimplementedError();

  @override
  Future<void> updateWritingMetadata(String userId, String writingId,
          {String? title,
          String? description,
          String? coverImagePath,
          ImageMeta? coverImageMeta,
          String? opId}) =>
      throw UnimplementedError();

  @override
  Future<void> deleteWriting(String userId, String writingId, {String? opId}) =>
      throw UnimplementedError();

  @override
  Future<void> addSection(String userId, String writingId, SectionModel section,
          {String? opId}) =>
      throw UnimplementedError();

  @override
  Future<void> updateSectionContent(
          String userId, String writingId, String sectionId, String content,
          {String canvasData = '', String? opId}) =>
      throw UnimplementedError();

  @override
  Future<void> renameSection(
          String userId, String writingId, String sectionId, String newTitle,
          {String? opId}) =>
      throw UnimplementedError();

  @override
  Future<void> deleteSection(String userId, String writingId, String sectionId,
          {String? opId}) =>
      throw UnimplementedError();

  @override
  Future<void> updateSectionMetadata(String userId, String writingId,
          String sectionId, Map<String, dynamic> fields,
          {String? opId}) =>
      throw UnimplementedError();

  @override
  Future<void> updateWritingProjectFields(
          String userId, String writingId, Map<String, dynamic> fields,
          {String? opId}) =>
      throw UnimplementedError();

  @override
  Future<String> upsertBookmark(BookmarkModel bookmark, {String? clientOpId}) =>
      throw UnimplementedError();

  @override
  Future<void> deleteBookmark(String bookmarkId) => throw UnimplementedError();
}

ConnectivityService _online() {
  final c = ConnectivityService();
  c.debugSet(true);
  return c;
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('integration_');
    Hive.init(tmp.path);
  });
  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('end-to-end: create + offset-patch + rename + delete roundtrip',
      () async {
    final outbox = Outbox(boxName: 'tb_int');
    await outbox.init();
    final server = _FakeServer();
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: server,
      connectivity: _online(),
    );

    // 1) Create with a local id.
    const localId = 'local-mark';
    await outbox.enqueue(PendingOp(
      id: localId,
      kind: PendingOpKind.upsertAuthorBookmark,
      payload: {
        'bookmarkId': localId,
        'fields': {
          'writing_id': 'w-1',
          'section_id': 'sec-1',
          'offset': 25,
          'label': 'fix later',
          'color': '#FFB300',
        },
      },
    ));

    // 2) Offset patch (simulating Quill delta math after the user typed
    //    before the marker). Local-id keyed; the drainer will rewrite
    //    this to the server id once the upsert lands.
    await outbox.enqueue(PendingOp(
      kind: PendingOpKind.patchAuthorBookmark,
      payload: {
        'bookmarkId': localId,
        'fields': {'offset': 80},
      },
    ));

    // 3) Rename — also local-id keyed.
    await outbox.enqueue(PendingOp(
      kind: PendingOpKind.patchAuthorBookmark,
      payload: {
        'bookmarkId': localId,
        'fields': {'label': 'foreshadow Daisy'},
      },
    ));

    await drainer.drain();

    // All three ops drained.
    expect(outbox.length, 0);
    // Server saw three calls: upsert (201), patch offset, patch label.
    expect(server.log.map((c) => c.method),
        ['upsert(201)', 'patch(200)', 'patch(200)']);
    // The server-side row reflects the final state.
    expect(server._store.length, 1);
    final saved = server._store.values.single;
    expect(saved.offset, 80);
    expect(saved.label, 'foreshadow Daisy');
    expect(saved.color, '#FFB300');
    // The patches ran against the server id, not the local one.
    final patchTargets =
        server.log.where((c) => c.method.startsWith('patch')).map((c) => c.id);
    expect(
      patchTargets.every((id) => id != null && id.startsWith('srv-')),
      true,
    );

    // 4) Delete
    await outbox.enqueue(PendingOp(
      kind: PendingOpKind.deleteAuthorBookmark,
      payload: {'bookmarkId': saved.id},
    ));
    await drainer.drain();
    expect(server._store, isEmpty);

    await drainer.dispose();
    await outbox.dispose();
  });

  test(
    'idempotent replay: a second upsert at the same (section, offset) returns the same row id',
    () async {
      final outbox = Outbox(boxName: 'tb_int_dedupe');
      await outbox.init();
      final server = _FakeServer();
      final drainer = OutboxDrainer(
        outbox: outbox,
        dataService: server,
        connectivity: _online(),
      );

      Future<void> enqueueAndDrain(String localId) async {
        await outbox.enqueue(PendingOp(
          id: localId,
          kind: PendingOpKind.upsertAuthorBookmark,
          payload: {
            'bookmarkId': localId,
            'fields': {
              'writing_id': 'w-1',
              'section_id': 'sec-x',
              'offset': 10,
              'color': '#FFB300',
            },
          },
        ));
        await drainer.drain();
      }

      await enqueueAndDrain('replay-1');
      await enqueueAndDrain('replay-2');

      // Two upserts hit the server, but only the first created a row;
      // the second is a 200-OK return on the existing row.
      expect(server.log.map((c) => c.method),
          ['upsert(201)', 'upsert(200)']);
      expect(server._store.length, 1);

      await drainer.dispose();
      await outbox.dispose();
    },
  );
}
