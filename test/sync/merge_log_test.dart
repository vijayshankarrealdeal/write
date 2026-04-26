import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:inkspacex/services/sync/merge_log.dart';

MergeLogEntry _entry(String sectionId, String winner) => MergeLogEntry(
      sectionId: sectionId,
      localUpdatedAt: DateTime.utc(2026, 4, 25),
      remoteUpdatedAt: DateTime.utc(2026, 4, 26),
      localLen: 42,
      remoteLen: 99,
      winner: winner,
    );

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('merge_log_test_');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('records and round-trips entries through Hive', () async {
    final log = MergeLog(boxName: 'tlog1');
    await log.init();
    await log.record(_entry('s1', 'local'));
    await log.record(_entry('s2', 'remote'));
    await log.dispose();

    final reopen = MergeLog(boxName: 'tlog1');
    await reopen.init();
    final entries = reopen.snapshot();
    expect(entries.length, 2);
    expect(entries[0].sectionId, 's1');
    expect(entries[0].winner, 'local');
    expect(entries[1].winner, 'remote');
  });

  test('caps length at maxEntries (oldest entries dropped)', () async {
    final log = MergeLog(boxName: 'tlog2', maxEntries: 3);
    await log.init();
    for (var i = 0; i < 5; i++) {
      await log.record(_entry('s$i', 'local'));
    }
    final entries = log.snapshot();
    expect(entries.length, 3);
    expect(entries.first.sectionId, 's2');
    expect(entries.last.sectionId, 's4');
  });
}
