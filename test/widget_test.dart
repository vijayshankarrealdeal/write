// Smoke test: the test binding boots and a MaterialApp pumps a frame.
//
// History — why this test is narrow on purpose. The original test
// constructed the full `MyApp` and called `pumpAndSettle`. That widget
// tree fans out a swarm of perpetual async work — auth restore, SSE
// subscriptions, periodic connectivity probes, image precache, the
// splash-screen activity indicator's Ticker, post-frame router init.
// `pumpAndSettle` waits for the binding to be quiescent, which it never
// is. The test ran out the 10-min default timeout on every CI run and
// muddied the signal until we replaced it (see plan.md "Bugs / known
// issues"). We deliberately do NOT remount the entire app under the
// flutter_test binding — that would require mocking every platform
// channel transitively reachable from the boot path, which is a
// disproportionate amount of plumbing for a smoke test.
//
// Real coverage of the app's surfaces lives in feature-scoped widget
// tests under `test/widgets/`, which build narrow Provider trees
// against fakes. Those tests already exercise the actual UX: editor,
// scrivenings view, footnote panel, bookmark inspector, etc.
//
// The job of this test is the cheapest possible signal that
// `flutter_test` is wired up and the framework can build a frame.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('flutter_test binding pumps a frame', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('inkspacex-smoke')),
        ),
      ),
    );

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('inkspacex-smoke'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
