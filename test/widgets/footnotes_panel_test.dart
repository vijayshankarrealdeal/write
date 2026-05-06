import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:inkspacex/models/footnote_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/footnotes_panel.dart';

SectionModel _section(List<FootnoteModel> footnotes) {
  return SectionModel(
    id: 'sec-1',
    title: 'Test Section',
    content: '',
    sectionColor: Colors.blueAccent,
    footnotes: footnotes,
  );
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('shows the empty placeholder when no footnotes exist',
      (tester) async {
    await tester.pumpWidget(_wrap(FootnotesPanel(
      section: _section(const []),
      isDark: false,
      textColor: Colors.black,
      borderColor: Colors.grey,
      onChanged: (_) {},
    )));
    expect(
      find.textContaining('No footnotes in this section yet.'),
      findsOneWidget,
    );
  });

  testWidgets('renders ¹, ², ³ for three footnotes', (tester) async {
    await tester.pumpWidget(_wrap(FootnotesPanel(
      section: _section([
        FootnoteModel(id: 'fn-1', text: 'one'),
        FootnoteModel(id: 'fn-2', text: 'two'),
        FootnoteModel(id: 'fn-3', text: 'three'),
      ]),
      isDark: false,
      textColor: Colors.black,
      borderColor: Colors.grey,
      onChanged: (_) {},
    )));
    expect(find.text('¹'), findsOneWidget);
    expect(find.text('²'), findsOneWidget);
    expect(find.text('³'), findsOneWidget);
  });

  testWidgets('typing in a footnote field calls onChanged with new text',
      (tester) async {
    List<FootnoteModel>? received;
    await tester.pumpWidget(_wrap(FootnotesPanel(
      section: _section([
        FootnoteModel(id: 'fn-only', text: 'orig'),
      ]),
      isDark: false,
      textColor: Colors.black,
      borderColor: Colors.grey,
      onChanged: (next) => received = next,
    )));
    await tester.enterText(find.byType(TextField), 'updated body');
    await tester.pump();
    expect(received, isNotNull);
    expect(received!.first.id, equals('fn-only'));
    expect(received!.first.text, equals('updated body'));
  });

  testWidgets('tapping delete removes the footnote from onChanged',
      (tester) async {
    List<FootnoteModel>? received;
    await tester.pumpWidget(_wrap(FootnotesPanel(
      section: _section([
        FootnoteModel(id: 'fn-keep', text: 'keep'),
        FootnoteModel(id: 'fn-go', text: 'go'),
      ]),
      isDark: false,
      textColor: Colors.black,
      borderColor: Colors.grey,
      onChanged: (next) => received = next,
    )));
    final deleteButtons = find.byTooltip('Delete footnote');
    expect(deleteButtons, findsNWidgets(2));
    await tester.tap(deleteButtons.last);
    await tester.pump();
    expect(received, isNotNull);
    expect(received!.length, equals(1));
    expect(received!.first.id, equals('fn-keep'));
  });

  testWidgets('jump button is hidden when onJumpToMarker is null',
      (tester) async {
    await tester.pumpWidget(_wrap(FootnotesPanel(
      section: _section([
        FootnoteModel(id: 'fn-only', text: 'cite'),
      ]),
      isDark: false,
      textColor: Colors.black,
      borderColor: Colors.grey,
      onChanged: (_) {},
    )));
    expect(find.byTooltip('Jump to marker'), findsNothing);
  });

  testWidgets('jump button fires the callback with the footnote id',
      (tester) async {
    String? jumped;
    await tester.pumpWidget(_wrap(FootnotesPanel(
      section: _section([
        FootnoteModel(id: 'fn-jumpable', text: 'cite'),
      ]),
      isDark: false,
      textColor: Colors.black,
      borderColor: Colors.grey,
      onJumpToMarker: (id) => jumped = id,
      onChanged: (_) {},
    )));
    await tester.tap(find.byTooltip('Jump to marker'));
    await tester.pump();
    expect(jumped, equals('fn-jumpable'));
  });
}
