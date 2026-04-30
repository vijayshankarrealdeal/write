import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:inkspacex/services/analytics_service.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('analytics_test_');
    Hive.init(tmp.path);
    AnalyticsService.resetSingletonForTest();
  });

  tearDown(() async {
    AnalyticsService.resetSingletonForTest();
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('track + flush hands events to the poster', () async {
    final captured = <List<Map<String, dynamic>>>[];
    final svc = await AnalyticsService.initForTest(
      poster: (events) async => captured.add(events),
    );
    svc.track('post_viewed', screen: '/post/:id', entityType: 'post', entityId: 'p1');
    svc.track('post_liked', screen: '/post/:id', entityType: 'post', entityId: 'p1');
    await svc.flush();

    expect(captured, hasLength(1));
    expect(captured.first.length, 2);
    expect(captured.first[0]['event_name'], 'post_viewed');
    expect(captured.first[1]['event_name'], 'post_liked');
    expect(captured.first[0]['client_id'], svc.clientId);
    // Both events share the same session_id within one launch.
    expect(captured.first[0]['session_id'], captured.first[1]['session_id']);
  });

  test('failed flush queues to disk and the next flush retries', () async {
    var fail = true;
    final captured = <List<Map<String, dynamic>>>[];

    final svc = await AnalyticsService.initForTest(
      poster: (events) async {
        if (fail) throw Exception('network down');
        captured.add(events);
      },
    );
    svc.track('auth_login_viewed', action: 'view');
    svc.track('auth_login_submitted', action: 'submit');
    await svc.flush();

    // Both events should now sit on disk under the analytics queue box.
    final box = Hive.box<dynamic>('analytics_queue');
    final raw = box.get('queue') as String?;
    expect(raw, isNotNull);
    expect(raw, contains('auth_login_viewed'));
    expect(raw, contains('auth_login_submitted'));

    // Recover and flush again — the disk queue should be drained.
    fail = false;
    await svc.flush();
    expect(captured, hasLength(1));
    expect(captured.first.length, 2);
    expect(box.get('queue'), isNull, reason: 'disk queue cleared after success');
  });

  test('client_id persists across reinit', () async {
    final svc1 = await AnalyticsService.initForTest(poster: (_) async {});
    final cid = svc1.clientId;
    expect(cid, isNotEmpty);

    AnalyticsService.resetSingletonForTest();

    final svc2 = await AnalyticsService.initForTest(poster: (_) async {});
    expect(svc2.clientId, cid,
        reason: 'client_id is what stitches anonymous → identified — must survive reinit');
  });

  test('events disabled when enabled=false', () async {
    var posted = 0;
    final svc = await AnalyticsService.initForTest(
      poster: (events) async => posted += events.length,
      enabled: false,
    );
    svc.track('something');
    await svc.flush();
    expect(posted, 0);
  });
}
