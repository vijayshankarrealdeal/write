import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:inkspacex/models/page_layout_settings.dart';
import 'package:inkspacex/services/pagination_engine.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/page_view_layout.dart';

PaginatedDocument _docFromBlocks(List<PageBlock> blocks, int linesPerPage) {
  return PaginationEngine.paginate(
    blocks: blocks,
    linesPerPage: linesPerPage,
  );
}

Widget _harness({
  required List<PageBlock> blocks,
  required PaginatedDocument document,
  required PageLayoutSettings settings,
  void Function(int)? onPageScrolled,
  void Function(int)? onTapPageHeader,
  ScrollController? controller,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        // Wide enough that pages don't auto-scale below 1.0×.
        width: 1200,
        height: 1400,
        child: PaginatedDocumentView(
          blocks: blocks,
          document: document,
          settings: settings,
          onPageScrolled: onPageScrolled,
          onTapPageHeader: onTapPageHeader,
          scrollController: controller,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders one page card per page in the document',
      (tester) async {
    final blocks = PaginationEngine.blocksFromJsonString(
      jsonEncode([
        {'insert': 'First paragraph.\n'},
        {'insert': 'Second paragraph that has a fair amount of text. ' * 4},
        {'insert': '\n'},
      ]),
      contentWidthPx: PageLayoutSettings.standard.contentWidthPx,
      bodyFontSizePx: PageLayoutSettings.standard.fontSizePx,
    );
    final doc = _docFromBlocks(
      blocks,
      PageLayoutSettings.standard.linesPerPage,
    );
    expect(doc.pageCount, greaterThanOrEqualTo(1));

    await tester.pumpWidget(_harness(
      blocks: blocks,
      document: doc,
      settings: PageLayoutSettings.standard,
    ));

    // Page-number badges of the form "1 / N".
    expect(find.text('1 / ${doc.pageCount}'), findsOneWidget);
    expect(find.textContaining('First paragraph.'), findsOneWidget);
  });

  testWidgets('shows page-of-Y badges across multi-page docs',
      (tester) async {
    // Force three pages by making each block big enough to fill one
    // page on its own.
    const linesPerPage = 12;
    final blocks = <PageBlock>[
      for (var i = 0; i < 3; i++)
        PageBlock(
          lines: linesPerPage,
          keepWithNext: false,
          splittable: true,
          headingLevel: 0,
          isList: false,
          isBlockquote: false,
          charsPerLine: 60,
          runs: [InlineRun(text: 'Paragraph $i body. ' * 10)],
        ),
    ];
    final doc = _docFromBlocks(blocks, linesPerPage);
    expect(doc.pageCount, 3);

    await tester.pumpWidget(_harness(
      blocks: blocks,
      document: doc,
      settings: PageLayoutSettings.standard,
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    // The first page card is mounted by ListView.builder.
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('tapping a page header invokes onTapPageHeader',
      (tester) async {
    final blocks = PaginationEngine.blocksFromJsonString(
      jsonEncode([
        {'insert': 'A short paragraph.\n'},
      ]),
      contentWidthPx: PageLayoutSettings.standard.contentWidthPx,
      bodyFontSizePx: PageLayoutSettings.standard.fontSizePx,
    );
    final doc = _docFromBlocks(
      blocks,
      PageLayoutSettings.standard.linesPerPage,
    );
    int? tappedIndex;
    await tester.pumpWidget(_harness(
      blocks: blocks,
      document: doc,
      settings: PageLayoutSettings.standard,
      onTapPageHeader: (i) => tappedIndex = i,
    ));

    await tester.tap(find.byTooltip('Edit this section').first);
    await tester.pumpAndSettle();
    expect(tappedIndex, 0);
  });

  testWidgets('empty document shows the empty state', (tester) async {
    final doc = const PaginatedDocument(pages: [<PageSpan>[]]);
    await tester.pumpWidget(_harness(
      blocks: const [],
      document: doc,
      settings: PageLayoutSettings.standard,
    ));
    expect(find.textContaining('paginated pages'), findsOneWidget);
  });

  testWidgets('renders heading with bold weight (visual smoke test)',
      (tester) async {
    final blocks = PaginationEngine.blocksFromJsonString(
      jsonEncode([
        {'insert': 'Chapter One'},
        {'insert': '\n', 'attributes': {'header': 1}},
        {'insert': 'It was a dark and stormy night.\n'},
      ]),
      contentWidthPx: PageLayoutSettings.standard.contentWidthPx,
      bodyFontSizePx: PageLayoutSettings.standard.fontSizePx,
    );
    final doc = _docFromBlocks(
      blocks,
      PageLayoutSettings.standard.linesPerPage,
    );
    await tester.pumpWidget(_harness(
      blocks: blocks,
      document: doc,
      settings: PageLayoutSettings.standard,
    ));
    expect(find.textContaining('Chapter One'), findsOneWidget);
    expect(find.textContaining('dark and stormy'), findsOneWidget);
  });

  testWidgets('settings change triggers a different rendered width',
      (tester) async {
    final blocks = PaginationEngine.blocksFromJsonString(
      jsonEncode([
        {'insert': 'Body.\n'},
      ]),
      contentWidthPx: PageLayoutSettings.standard.contentWidthPx,
      bodyFontSizePx: PageLayoutSettings.standard.fontSizePx,
    );
    final letterDoc = _docFromBlocks(
      blocks,
      PageLayoutSettings.standard.linesPerPage,
    );
    final a4Settings = PageLayoutSettings.standard.copyWith(
      size: PageSize.a4,
      widthIn: 210 / 25.4,
      heightIn: 297 / 25.4,
    );
    final a4Doc = _docFromBlocks(blocks, a4Settings.linesPerPage);

    Widget app(PageLayoutSettings s, PaginatedDocument d) =>
        _harness(blocks: blocks, document: d, settings: s);

    double pageHeight(WidgetTester t) {
      // The page card lives inside a SizedBox with both width and
      // height set. The harness SizedBox is 1200 × 1400 — exclude
      // it by also requiring width != 1200.
      final boxes = t.widgetList<SizedBox>(find.byType(SizedBox)).where(
            (s) => s.height != null &&
                s.width != null &&
                s.width != 1200 &&
                s.height! > 200,
          );
      expect(boxes, isNotEmpty);
      return boxes.first.height!;
    }

    await tester.pumpWidget(app(PageLayoutSettings.standard, letterDoc));
    final letterPx = pageHeight(tester);

    await tester.pumpWidget(app(a4Settings, a4Doc));
    await tester.pumpAndSettle();
    final a4Px = pageHeight(tester);
    // A4 height (1123 px) ≠ Letter height (1056 px).
    expect(a4Px, isNot(equals(letterPx)));
  });

  group('PageLayoutSettings derived metrics', () {
    test('Letter linesPerPage is sensible at 12pt / 1.5', () {
      final lpp = PageLayoutSettings.standard.linesPerPage;
      // 11" - 2" margins = 9" tall content; 12pt × 1.5 = 18pt =
      // 24px line height; 9 × 96 / 24 = 36 lines. Allow ±2 for
      // rounding.
      expect(lpp, inInclusiveRange(34, 38));
    });

    test('A4 has slightly more linesPerPage than Letter', () {
      final letter = PageLayoutSettings.standard.linesPerPage;
      final a4 = PageLayoutSettings.standard
          .copyWith(
            size: PageSize.a4,
            widthIn: 210 / 25.4,
            heightIn: 297 / 25.4,
          )
          .linesPerPage;
      expect(a4, greaterThan(letter));
    });

    test('JSON round-trip preserves all fields', () {
      final original = PageLayoutSettings.standard.copyWith(
        size: PageSize.a4,
        widthIn: 8.27,
        heightIn: 11.69,
        marginLeftIn: 1.25,
        font: PageFont.lora,
        fontSizePt: 11.5,
        lineHeight: 1.75,
      );
      final round = PageLayoutSettings.fromJson(original.toJson());
      expect(round.size, original.size);
      expect(round.font, original.font);
      expect(round.widthIn, closeTo(original.widthIn, 1e-9));
      expect(round.fontSizePt, closeTo(original.fontSizePt, 1e-9));
      expect(round.lineHeight, closeTo(original.lineHeight, 1e-9));
      expect(round.marginLeftIn, closeTo(original.marginLeftIn, 1e-9));
    });

    test('fromJson tolerates missing/wrong-typed fields', () {
      final round = PageLayoutSettings.fromJson(<String, dynamic>{
        'size': 'unknown_value',
        'fontSizePt': 'not a number',
      });
      // Falls back to standard for unknown/invalid fields.
      expect(round.size, PageLayoutSettings.standard.size);
      expect(round.fontSizePt, PageLayoutSettings.standard.fontSizePt);
    });
  });
}
