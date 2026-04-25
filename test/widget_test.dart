// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:inkspacex/main.dart';
import 'package:inkspacex/services/storage_service.dart';

void main() {
  testWidgets('App initializes correctly', (WidgetTester tester) async {
    // Initialize storage service
    final storage = StorageService();
    await storage.init();

    // Build our app and trigger a frame.
    await tester.pumpWidget(MyApp(storage: storage));

    // Verify the app loads
    await tester.pumpAndSettle();

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
