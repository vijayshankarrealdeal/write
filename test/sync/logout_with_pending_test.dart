import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:inkspacex/services/sync/outbox.dart';

import '_helpers.dart';

/// The contract: each user has their own outbox slot, keyed by uid. On
/// logout the slot is closed (not wiped) — the same user resumes on next
/// sign-in. A different user signing in opens a different slot, so one
/// user's queued ops can never be drained under another user's auth.
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

  test('outbox slot survives logout and resumes for the same user', () async {
    final outbox = Outbox();
    await outbox.init();
    await outbox.switchUser('user-a');
    await outbox.enqueue(contentOp('w1', 's1', '"unsynced edit"'));
    expect(outbox.length, 1);

    // Logout closes the slot but leaves the on-disk box untouched.
    await outbox.switchUser(null);
    expect(outbox.isOpen, isFalse);
    expect(outbox.length, 0);

    // Same user signs back in — the queued op is still there.
    await outbox.switchUser('user-a');
    expect(outbox.length, 1);
    expect(outbox.snapshot().single.payload['sectionId'], 's1');
  });

  test('a different user signing in opens a different slot', () async {
    final outbox = Outbox();
    await outbox.init();

    // User A queues an op, then logs out.
    await outbox.switchUser('user-a');
    await outbox.enqueue(contentOp('w1', 's1', '"A wrote this"'));
    await outbox.switchUser(null);

    // User B signs in on the same device. Their outbox is empty —
    // User A's queued op is invisible to them.
    await outbox.switchUser('user-b');
    expect(outbox.length, 0,
        reason: 'user-b must not see user-a\'s queued ops');

    // User B's own queue is independent.
    await outbox.enqueue(contentOp('w2', 's2', '"B wrote this"'));
    expect(outbox.length, 1);
    expect(outbox.snapshot().single.payload['sectionId'], 's2');

    // And user A's slot is untouched on disk.
    await outbox.switchUser('user-a');
    expect(outbox.length, 1);
    expect(outbox.snapshot().single.payload['sectionId'], 's1');
  });

  test('Outbox.clear() wipes pending ops in the current slot only', () async {
    final outbox = Outbox();
    await outbox.init();
    await outbox.switchUser('user-a');
    await outbox.enqueue(contentOp('w1', 's1', '"unsynced"'));
    await outbox.enqueue(contentOp('w1', 's2', '"unsynced 2"'));
    expect(outbox.length, 2);

    await outbox.clear();
    expect(outbox.isEmpty, isTrue);
    expect(outbox.pendingCount.value, 0);
  });

  test('enqueue with no user scope throws', () async {
    final outbox = Outbox();
    await outbox.init();
    expect(
      () => outbox.enqueue(contentOp('w1', 's1', '"oops"')),
      throwsA(isA<StateError>()),
    );
  });
}
