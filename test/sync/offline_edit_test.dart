import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:inkspacex/services/connectivity_service.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/outbox_drainer.dart';

import '_helpers.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('offline_edit_test_');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('offline edits land on the server in order once back online', () async {
    final outbox = Outbox(boxName: 'offline_edit');
    await outbox.init();
    final connectivity = ConnectivityService()..debugSet(false);
    final dispatcher = RecordingDispatcher();
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: connectivity,
      backoff: (_) => Duration.zero,
      sleep: (_) async {},
    );

    // User edits three sections while offline. With Phase 2's outbox,
    // every mutation enqueues immediately rather than dropping on the
    // floor.
    await outbox.enqueue(contentOp('w1', 's1', '"first edit"'));
    await outbox.enqueue(contentOp('w1', 's2', '"second edit"'));
    await outbox.enqueue(contentOp('w1', 's1', '"first edit, revised"'));

    // No network calls happened yet — drainer respects the offline flag.
    drainer.kick();
    await Future<void>.delayed(Duration.zero);
    expect(dispatcher.calls, isEmpty);
    expect(outbox.length, 3);

    // Connection comes back. The drainer's connectivity listener kicks
    // the queue; the test awaits the resulting drain explicitly.
    connectivity.debugSet(true);
    await drainer.drain();

    // Order is preserved: each edit reached the server in the order it
    // was queued, including the second edit on s1 that came after s2.
    expect(dispatcher.calls, [
      'updateSectionContent:w1/s1',
      'updateSectionContent:w1/s2',
      'updateSectionContent:w1/s1',
    ]);
    expect(outbox.isEmpty, isTrue);

    await drainer.dispose();
    await outbox.dispose();
    await connectivity.dispose();
  });
}
