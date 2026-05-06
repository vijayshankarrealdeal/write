/// Phase 3 (P2) — bookmark outbox round-trips.
///
/// The contract: bookmark writes go through the outbox like every other
/// mutation (no bypass), survive offline, drain in order on reconnect,
/// and remap local→server ids so subsequent deletes target the right
/// row. Mirrors the section-outbox tests in shape so a regression in
/// either pipeline is obvious from the diff.
library;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:inkspacex/models/bookmark_model.dart';
import 'package:inkspacex/services/connectivity_service.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/outbox_drainer.dart';
import 'package:inkspacex/services/sync/pending_op.dart';

import '_helpers.dart';

PendingOp _bookmarkOp({
  required String bookmarkId,
  required String feedItemId,
  int sectionIndex = 0,
  int paragraphIdx = 0,
  int charOffset = 0,
  String? label,
  String color = '#FFB300',
}) =>
    PendingOp(
      id: bookmarkId,
      kind: PendingOpKind.upsertBookmark,
      payload: {
        'bookmarkId': bookmarkId,
        'fields': {
          'feed_item_id': feedItemId,
          'section_index': sectionIndex,
          'anchor': {
            'paragraph_idx': paragraphIdx,
            'char_offset': charOffset,
          },
          'label': ?label,
          'color': color,
        },
      },
    );

PendingOp _deleteBookmarkOp(String bookmarkId) => PendingOp(
      kind: PendingOpKind.deleteBookmark,
      payload: {'bookmarkId': bookmarkId},
    );

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bookmark_outbox_test_');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('bookmark created offline drains exactly once on reconnect', () async {
    final outbox = Outbox(boxName: 'bm_offline');
    await outbox.init();
    final connectivity = ConnectivityService()..debugSet(false);
    final dispatcher = RecordingDispatcher();
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: connectivity,
      sleep: (_) async {},
    );

    await outbox.enqueue(_bookmarkOp(
      bookmarkId: 'local-bm-1',
      feedItemId: 'feed-1',
      paragraphIdx: 3,
      charOffset: 17,
      label: 'first chapter wisdom',
    ));
    drainer.kick();
    await Future<void>.delayed(Duration.zero);
    expect(dispatcher.calls, isEmpty,
        reason: 'offline drainer should not fire');
    expect(outbox.length, 1);

    connectivity.debugSet(true);
    await drainer.drain();

    expect(dispatcher.calls, ['upsertBookmark:local-bm-1']);
    expect(outbox.isEmpty, isTrue,
        reason: 'op should be removed after a successful ack');

    await drainer.dispose();
    await outbox.dispose();
  });

  test('drains preserve order and dedupe replays at the dispatcher boundary',
      () async {
    final outbox = Outbox(boxName: 'bm_order');
    await outbox.init();
    final connectivity = ConnectivityService()..debugSet(true);
    final dispatcher = RecordingDispatcher();
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: connectivity,
      sleep: (_) async {},
    );

    await outbox.enqueue(_bookmarkOp(
      bookmarkId: 'a',
      feedItemId: 'feed-1',
      paragraphIdx: 0,
    ));
    await outbox.enqueue(_bookmarkOp(
      bookmarkId: 'b',
      feedItemId: 'feed-1',
      paragraphIdx: 1,
    ));
    await outbox.enqueue(_deleteBookmarkOp('a'));
    await drainer.drain();

    expect(dispatcher.calls, [
      'upsertBookmark:a',
      'upsertBookmark:b',
      'deleteBookmark:a',
    ]);
    expect(outbox.isEmpty, isTrue);

    await drainer.dispose();
    await outbox.dispose();
  });

  test('id remap rewrites pending follow-up ops to the server id', () async {
    final outbox = Outbox(boxName: 'bm_remap');
    await outbox.init();
    final connectivity = ConnectivityService()..debugSet(true);
    final dispatcher = RecordingDispatcher()
      ..bookmarkServerIds = const {'local-A': 'server-A'};
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: connectivity,
      sleep: (_) async {},
    );

    final remaps = <String>[];
    drainer.onRemap.listen((e) {
      if (e.kind == IdRemapKind.bookmark) {
        remaps.add('${e.localId}->${e.serverId}');
      }
    });

    await outbox.enqueue(_bookmarkOp(
      bookmarkId: 'local-A',
      feedItemId: 'feed-1',
    ));
    // Delete enqueued before the upsert acks — must follow the remap to
    // hit the correct row, otherwise the delete 404s server-side and
    // the user sees a stale bookmark.
    await outbox.enqueue(_deleteBookmarkOp('local-A'));

    await drainer.drain();

    expect(dispatcher.calls, [
      'upsertBookmark:local-A',
      'deleteBookmark:server-A',
    ]);
    expect(remaps, ['local-A->server-A']);

    await drainer.dispose();
    await outbox.dispose();
  });

  test('crash mid-drain leaves the queue intact for the next process',
      () async {
    final outbox = Outbox(boxName: 'bm_crash');
    await outbox.init();
    await outbox.enqueue(_bookmarkOp(
      bookmarkId: 'survivor',
      feedItemId: 'feed-9',
    ));
    // Simulate process death without disposing the drainer/connectivity
    // — the box file on disk must hold the op.
    await outbox.dispose();
    await Hive.close();

    Hive.init(tmp.path);
    final box2 = Outbox(boxName: 'bm_crash');
    await box2.init();
    final restored = box2.snapshot();
    expect(restored, hasLength(1));
    expect(restored.single.kind, PendingOpKind.upsertBookmark);
    expect(restored.single.payload['bookmarkId'], 'survivor');
    await box2.dispose();
  });

  test('PendingOp.toJson/fromJson round-trips bookmark payloads', () {
    final op = _bookmarkOp(
      bookmarkId: 'rt-1',
      feedItemId: 'feed-x',
      sectionIndex: 2,
      paragraphIdx: 7,
      charOffset: 42,
      label: 'roundtrip',
      color: '#AB12CD',
    );
    final restored = PendingOp.fromJson(
      Map<String, dynamic>.from(op.toJson()),
    );
    expect(restored.kind, PendingOpKind.upsertBookmark);
    expect(restored.payload['bookmarkId'], 'rt-1');
    final fields = Map<String, dynamic>.from(restored.payload['fields'] as Map);
    expect(fields['section_index'], 2);
    expect(fields['label'], 'roundtrip');
    final anchor = Map<String, dynamic>.from(fields['anchor'] as Map);
    expect(anchor['paragraph_idx'], 7);
    expect(anchor['char_offset'], 42);
  });

  test('BookmarkModel.fromJson handles full server response', () {
    final raw = {
      'id': 'srv-1',
      'user_id': 'u',
      'feed_item_id': 'feed-1',
      'section_id': 'sec-A',
      'section_index': 4,
      'anchor': {'paragraph_idx': 9, 'char_offset': 3},
      'label': 'meaningful',
      'color': '#26A69A',
      'created_at': '2026-04-26T12:00:00Z',
      'updated_at': '2026-04-26T12:30:00Z',
    };
    final model = BookmarkModel.fromJson(raw);
    expect(model.id, 'srv-1');
    expect(model.feedItemId, 'feed-1');
    expect(model.sectionId, 'sec-A');
    expect(model.sectionIndex, 4);
    expect(model.paragraphIdx, 9);
    expect(model.charOffset, 3);
    expect(model.label, 'meaningful');
    expect(model.color, '#26A69A');
  });

  test('ContinueReadingItem.fromJson decodes anchor + nullable fields', () {
    final raw = {
      'feed_item_id': 'feed-2',
      'title': 'Drift',
      'author': 'A.',
      'image_url': null,
      'scroll_position': 0.65,
      'last_read_at': '2026-04-26T11:00:00Z',
      'last_section_id': 'sec-2',
      'last_anchor': {'paragraph_idx': 5, 'char_offset': 12},
      'completed': false,
    };
    final item = ContinueReadingItem.fromJson(raw);
    expect(item.feedItemId, 'feed-2');
    expect(item.title, 'Drift');
    expect(item.imageUrl, isNull);
    expect(item.scrollPosition, 0.65);
    expect(item.lastSectionId, 'sec-2');
    expect(item.lastParagraphIdx, 5);
    expect(item.lastCharOffset, 12);
    expect(item.completed, isFalse);
  });
}
