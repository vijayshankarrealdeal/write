// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:inkspacex/main.dart';
import 'package:inkspacex/services/connectivity_service.dart';
import 'package:inkspacex/services/local_notification_service.dart';
import 'package:inkspacex/services/storage_service.dart';
import 'package:inkspacex/services/sync/merge_log.dart';
import 'package:inkspacex/services/sync/outbox.dart';

void main() {
  testWidgets('App initializes correctly', (WidgetTester tester) async {
    // Initialize storage service
    final storage = StorageService();
    await storage.init();
    final connectivity = ConnectivityService();
    connectivity.debugSet(true);
    final outbox = Outbox(boxName: 'sync_outbox_test');
    await outbox.init();
    final mergeLog = MergeLog(boxName: 'sync_merge_log_test');
    await mergeLog.init();
    final localNotifications = LocalNotificationService();
    // init() is a no-op in the test environment (no platform channels);
    // we don't await it because plugin init isn't available offline.

    // Build our app and trigger a frame.
    await tester.pumpWidget(
      MyApp(
        storage: storage,
        connectivity: connectivity,
        outbox: outbox,
        mergeLog: mergeLog,
        localNotifications: localNotifications,
      ),
    );

    // Verify the app loads
    await tester.pumpAndSettle();

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
