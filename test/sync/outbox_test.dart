import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/pending_op.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('outbox_test_');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  PendingOp _op(String name) => PendingOp(
        kind: PendingOpKind.upsertSection,
        payload: {
          'writingId': 'w1',
          'sectionId': 's-$name',
          'isNew': false,
          'fields': {'content': '"$name"'},
        },
      );

  test('round-trips an op through restart (Hive-backed)', () async {
    final box1 = Outbox(boxName: 'tb1');
    await box1.init();
    final op = _op('alpha');
    await box1.enqueue(op);
    expect(box1.length, 1);
    expect(box1.pendingCount.value, 1);
    await box1.dispose();

    final box2 = Outbox(boxName: 'tb1');
    await box2.init();
    expect(box2.length, 1);
    final restored = box2.snapshot().single;
    expect(restored.id, op.id);
    expect(restored.kind, op.kind);
    expect(restored.payload['sectionId'], 's-alpha');
    await box2.dispose();
  });

  test('preserves enqueue order across multiple ops', () async {
    final box = Outbox(boxName: 'tb_order');
    await box.init();
    final names = ['a', 'b', 'c', 'd'];
    for (final n in names) {
      await box.enqueue(_op(n));
    }
    final ids = box.snapshot().map((o) => o.payload['sectionId']).toList();
    expect(ids, names.map((n) => 's-$n').toList());
    await box.dispose();
  });

  test('remove drops only the targeted op', () async {
    final box = Outbox(boxName: 'tb_remove');
    await box.init();
    final a = _op('a');
    final b = _op('b');
    await box.enqueue(a);
    await box.enqueue(b);
    await box.remove(a.id);
    final remaining = box.snapshot();
    expect(remaining.length, 1);
    expect(remaining.single.id, b.id);
    await box.dispose();
  });

  test('update bumps attemptCount in place and persists across reopens',
      () async {
    final box = Outbox(boxName: 'tb_update');
    await box.init();
    final op = _op('retry');
    await box.enqueue(op);
    await box.update(op.copyWith(attemptCount: 3, lastError: 'boom'));
    await box.dispose();

    final box2 = Outbox(boxName: 'tb_update');
    await box2.init();
    final reloaded = box2.snapshot().single;
    expect(reloaded.attemptCount, 3);
    expect(reloaded.lastError, 'boom');
    await box2.dispose();
  });

  test('rewriteAll lets the drainer remap ids on every queued op', () async {
    final box = Outbox(boxName: 'tb_rewrite');
    await box.init();
    await box.enqueue(_op('a'));
    await box.enqueue(_op('b'));
    await box.rewriteAll((op) {
      final p = Map<String, dynamic>.from(op.payload);
      p['writingId'] = 'remote-w1';
      return op.copyWith(payload: p);
    });
    final ops = box.snapshot();
    expect(ops.every((o) => o.payload['writingId'] == 'remote-w1'), isTrue);
    await box.dispose();
  });

  test('clear empties the queue and resets pendingCount', () async {
    final box = Outbox(boxName: 'tb_clear');
    await box.init();
    await box.enqueue(_op('x'));
    await box.enqueue(_op('y'));
    await box.clear();
    expect(box.isEmpty, isTrue);
    expect(box.pendingCount.value, 0);
    await box.dispose();
  });
}
