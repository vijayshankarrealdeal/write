import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:inkspacex/services/sync/outbox.dart';

import '_helpers.dart';

/// The contract: the outbox lives in its own Hive box and is **not**
/// wiped by the books-store clear-down that runs on logout. Logout is
/// silent (no "unsynced edits" prompt) — the queue persists and drains
/// the next time the user signs in.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('logout_with_pending_test_');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('outbox survives a clearBooks-equivalent (the books-blob wipe)',
      () async {
    // The outbox uses its own Hive box, so wiping the books box must not
    // touch the queue.
    final outbox = Outbox(boxName: 'logout_pending');
    await outbox.init();
    final booksBox = await Hive.openBox('writer_app_box');

    await outbox.enqueue(contentOp('w1', 's1', '"unsynced edit"'));
    await booksBox.put('user_books_json', <String>['some payload']);
    expect(outbox.length, 1);
    expect(booksBox.get('user_books_json'), isNotEmpty);

    // Simulate StorageService.clearBooks() — it deletes the books key,
    // not the box.
    await booksBox.delete('user_books_json');

    // Outbox is untouched.
    expect(outbox.length, 1);
    final survivor = outbox.snapshot().single;
    expect(survivor.payload['sectionId'], 's1');

    await booksBox.close();
    await outbox.dispose();
  });

  test('Outbox.clear() wipes pending ops', () async {
    final outbox = Outbox(boxName: 'logout_discard');
    await outbox.init();
    await outbox.enqueue(contentOp('w1', 's1', '"unsynced"'));
    await outbox.enqueue(contentOp('w1', 's2', '"unsynced 2"'));
    expect(outbox.length, 2);

    await outbox.clear();
    expect(outbox.isEmpty, isTrue);
    expect(outbox.pendingCount.value, 0);

    await outbox.dispose();
  });
}
