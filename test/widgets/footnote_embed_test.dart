import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:inkspacex/models/footnote_model.dart';
import 'package:inkspacex/ui/editor/footnote_embed_builder.dart';

/// Build a QuillEditor whose document is a paragraph with a single
/// footnote embed inserted between two text spans. The test then
/// verifies the embed builder renders the marker as the expected
/// superscript number, derived from the footnote list's order.
Widget _buildEditorWithFootnote({
  required String embedId,
  required List<FootnoteModel> footnotes,
  void Function(String)? onTap,
}) {
  final controller = QuillController.basic();
  controller.document.insert(0, 'before ');
  controller.document.insert(7, FootnoteBlockEmbed.of(embedId));
  controller.document.insert(8, ' after');
  return MaterialApp(
    home: Scaffold(
      body: QuillEditor.basic(
        controller: controller,
        config: QuillEditorConfig(
          embedBuilders: [
            FootnoteEmbedBuilder(
              footnotesProvider: () => footnotes,
              onTapMarker: onTap,
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders ¹ for the first footnote in the list', (tester) async {
    await tester.pumpWidget(_buildEditorWithFootnote(
      embedId: 'fn-only',
      footnotes: [FootnoteModel(id: 'fn-only', text: 'cite')],
    ));
    expect(find.text('¹'), findsOneWidget);
  });

  testWidgets('renders ³ when the embed is the third entry', (tester) async {
    await tester.pumpWidget(_buildEditorWithFootnote(
      embedId: 'fn-third',
      footnotes: [
        FootnoteModel(id: 'fn-a', text: 'a'),
        FootnoteModel(id: 'fn-b', text: 'b'),
        FootnoteModel(id: 'fn-third', text: 'c'),
      ],
    ));
    expect(find.text('³'), findsOneWidget);
  });

  testWidgets('shows a "?" marker when the embed id is unknown',
      (tester) async {
    await tester.pumpWidget(_buildEditorWithFootnote(
      embedId: 'fn-deleted',
      footnotes: const [],
    ));
    expect(find.text('?'), findsOneWidget);
  });

  testWidgets('tapping the marker invokes onTapMarker with the id',
      (tester) async {
    String? tappedId;
    await tester.pumpWidget(_buildEditorWithFootnote(
      embedId: 'fn-clicker',
      footnotes: [FootnoteModel(id: 'fn-clicker', text: 'cite')],
      onTap: (id) => tappedId = id,
    ));
    await tester.tap(find.text('¹'));
    await tester.pump();
    expect(tappedId, equals('fn-clicker'));
  });
}
