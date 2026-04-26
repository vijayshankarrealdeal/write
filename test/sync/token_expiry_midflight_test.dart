import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/connectivity_service.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/outbox_drainer.dart';

import '_helpers.dart';

/// Token expiry semantics: the [ApiClient] handles 401 by transparently
/// refreshing the token and retrying ONCE before returning to the
/// drainer. If the refresh ALSO fails, a 401 finally bubbles up — the
/// drainer treats that as transient (user might re-authenticate later)
/// and schedules a retry at the regular backoff cadence.
///
/// We can't unit-test the refresh-and-retry inside ApiClient (it's an
/// HTTP integration), but we *can* pin the drainer's behavior when a
/// 401 actually does reach it.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('token_expiry_test_');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('401 is treated as transient and the op is replayed', () async {
    final outbox = Outbox(boxName: 'token_401');
    await outbox.init();
    final connectivity = ConnectivityService()..debugSet(true);
    final dispatcher = RecordingDispatcher()
      ..scriptUpdateSectionContent([
        ApiException(
          statusCode: 401,
          message: 'token expired',
          type: ApiErrorType.badResponse,
        ),
        null, // success after the user re-authenticates
      ]);
    final drainer = OutboxDrainer(
      outbox: outbox,
      dataService: dispatcher,
      connectivity: connectivity,
      backoff: (_) => Duration.zero,
      sleep: (_) async {},
    );

    await outbox.enqueue(contentOp('w1', 's1', '"hi"'));

    await drainer.drain();
    // First attempt: 401, op stays queued (transient classification).
    final afterFirst = outbox.snapshot();
    expect(afterFirst.length, 1);
    expect(afterFirst.single.failed, isFalse);
    expect(afterFirst.single.attemptCount, 1);

    // Clear the cooldown that backoff just set, drain again.
    await outbox.update(afterFirst.single.copyWith(clearNextAttempt: true));
    await drainer.drain();
    expect(outbox.isEmpty, isTrue);
    expect(dispatcher.calls.length, 2);

    await drainer.dispose();
    await outbox.dispose();
    await connectivity.dispose();
  });
}
