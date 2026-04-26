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
    tmp = await Directory.systemTemp.createTemp('crash_recovery_test_');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('queued ops survive a process kill and drain on next launch',
      () async {
    // Round 1: enqueue ops, simulate a crash before any of them push.
    final outbox1 = Outbox(boxName: 'crash_recover');
    await outbox1.init();
    await outbox1.enqueue(contentOp('w1', 's1', '"a"'));
    await outbox1.enqueue(contentOp('w1', 's2', '"b"'));
    await outbox1.enqueue(contentOp('w1', 's3', '"c"'));
    expect(outbox1.length, 3);

    // Simulate a hard kill: close the box without further work, then
    // close Hive so the next round mimics a cold start.
    await outbox1.dispose();
    await Hive.close();

    // Round 2: re-init Hive, reopen the same box (same boxName, same
    // path), drain into a fresh dispatcher.
    Hive.init(tmp.path);
    final outbox2 = Outbox(boxName: 'crash_recover');
    await outbox2.init();
    expect(outbox2.length, 3,
        reason: 'queue must survive crash without losing ops');

    final connectivity = ConnectivityService()..debugSet(true);
    final dispatcher = RecordingDispatcher();
    final drainer = OutboxDrainer(
      outbox: outbox2,
      dataService: dispatcher,
      connectivity: connectivity,
      backoff: (_) => Duration.zero,
      sleep: (_) async {},
    );

    await drainer.drain();
    expect(outbox2.isEmpty, isTrue);
    expect(dispatcher.calls, [
      'updateSectionContent:w1/s1',
      'updateSectionContent:w1/s2',
      'updateSectionContent:w1/s3',
    ]);

    await drainer.dispose();
    await outbox2.dispose();
    await connectivity.dispose();
  });

  test('attempt history survives a crash mid-retry', () async {
    final outbox1 = Outbox(boxName: 'crash_retry');
    await outbox1.init();
    final connectivity1 = ConnectivityService()..debugSet(true);
    final dispatcher1 = RecordingDispatcher()
      ..scriptUpdateSectionContent([Exception('boom')]);
    final drainer1 = OutboxDrainer(
      outbox: outbox1,
      dataService: dispatcher1,
      connectivity: connectivity1,
      backoff: (_) => Duration.zero,
      sleep: (_) async {},
    );

    await outbox1.enqueue(contentOp('w1', 's1', '"a"'));
    await drainer1.drain();
    expect(outbox1.snapshot().single.attemptCount, 1);
    await drainer1.dispose();
    await outbox1.dispose();
    await connectivity1.dispose();
    await Hive.close();

    // Cold start: the persisted attemptCount comes back.
    Hive.init(tmp.path);
    final outbox2 = Outbox(boxName: 'crash_retry');
    await outbox2.init();
    expect(outbox2.snapshot().single.attemptCount, 1,
        reason: 'attempt history must persist across restarts');

    await outbox2.dispose();
  });
}
