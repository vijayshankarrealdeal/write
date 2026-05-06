// Widget test for the "Go to page" dialog wired into ⌘G / Ctrl-G.
// The dialog reads its hint text and validator bound from the live
// PageViewController.totalPages, and on submit calls
// `controller.goToPage(N)`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/page_view_layout.dart';

class _StubController extends PageViewController {
  final List<int> jumps = [];
  bool nextResult = true;

  @override
  bool goToPage(int pageNumber) {
    jumps.add(pageNumber);
    return nextResult;
  }
}

Widget _harness(Future<void> Function(BuildContext) onTap) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => onTap(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('dialog calls goToPage on submit', (tester) async {
    final controller = _StubController();
    addTearDown(controller.dispose);
    controller.debugSetTotalPages(20);

    await tester.pumpWidget(_harness((ctx) async {
      await showGoToPageDialog(context: ctx, controller: controller);
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Dialog is open.
    expect(find.text('Go to page'), findsOneWidget);
    expect(find.byType(TextFormField), findsOneWidget);
    expect(find.text('1 – 20'), findsOneWidget,
        reason: 'hint should reflect controller.totalPages');

    // Type a valid page and submit.
    await tester.enterText(find.byType(TextFormField), '7');
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    expect(controller.jumps, equals(<int>[7]));
    // Dialog dismissed.
    expect(find.text('Go to page'), findsNothing);
  });

  testWidgets('dialog rejects out-of-range and non-numeric input',
      (tester) async {
    final controller = _StubController();
    addTearDown(controller.dispose);
    controller.debugSetTotalPages(5);

    await tester.pumpWidget(_harness((ctx) async {
      await showGoToPageDialog(context: ctx, controller: controller);
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Out of range — totalPages = 5.
    await tester.enterText(find.byType(TextFormField), '99');
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(controller.jumps, isEmpty);
    expect(find.text('Go to page'), findsOneWidget,
        reason: 'invalid input must keep the dialog open');

    // Non-numeric — also rejected.
    await tester.enterText(find.byType(TextFormField), 'banana');
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(controller.jumps, isEmpty);
    expect(find.text('Go to page'), findsOneWidget);
  });

  testWidgets('Cancel dismisses the dialog without calling goToPage',
      (tester) async {
    final controller = _StubController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_harness((ctx) async {
      await showGoToPageDialog(context: ctx, controller: controller);
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.jumps, isEmpty);
    expect(find.text('Go to page'), findsNothing);
  });
}
