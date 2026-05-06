import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/services/pagination_engine.dart';

PageBlock _para(int lines, {bool splittable = true}) => PageBlock(
      lines: lines,
      keepWithNext: false,
      splittable: splittable,
      headingLevel: 0,
      isList: false,
      isBlockquote: false,
    );

PageBlock _heading(int lines) => PageBlock(
      lines: lines,
      keepWithNext: true,
      splittable: false,
      headingLevel: 1,
      isList: false,
      isBlockquote: false,
    );

PageBlock _embed() => const PageBlock(
      lines: 6,
      keepWithNext: false,
      splittable: false,
      headingLevel: 0,
      isList: false,
      isBlockquote: false,
      isEmbed: true,
    );

void main() {
  group('PaginationEngine.paginate — basic flow', () {
    test('empty input yields one empty page', () {
      final doc = PaginationEngine.paginate(blocks: const [], linesPerPage: 10);
      expect(doc.pageCount, 1);
      expect(doc.pages.first, isEmpty);
    });

    test('three blocks fit on one page', () {
      final doc = PaginationEngine.paginate(
        blocks: [_para(3), _para(3), _para(3)],
        linesPerPage: 10,
      );
      expect(doc.pageCount, 1);
      expect(doc.pages.first.length, 3);
      expect(doc.totalLines, 9);
    });

    test('blocks overflow onto a second page (no split needed)', () {
      final doc = PaginationEngine.paginate(
        blocks: [_para(5), _para(5), _para(5)],
        linesPerPage: 10,
      );
      expect(doc.pageCount, 2);
      expect(doc.pages[0].map((s) => s.blockIndex).toList(), [0, 1]);
      expect(doc.pages[1].map((s) => s.blockIndex).toList(), [2]);
    });
  });

  group('PaginationEngine.paginate — splitting & widow/orphan', () {
    test('paragraph splits across pages with widow/orphan honored', () {
      // remaining=2 on page 1, 5-line paragraph that wants to split
      final doc = PaginationEngine.paginate(
        blocks: [_para(5), _para(5), _para(5)],
        linesPerPage: 12,
      );
      // Page 1 fits the first two 5-line blocks (10 lines) and 2 lines
      // of the third (orphan = 2). Page 2 gets the remaining 3 lines
      // (>= widow = 2).
      expect(doc.pageCount, 2);
      expect(doc.pages[0].length, 3);
      final lastSpanP1 = doc.pages[0].last;
      expect(lastSpanP1.blockIndex, 2);
      expect(lastSpanP1.startLine, 0);
      expect(lastSpanP1.endLine, 2);
      expect(lastSpanP1.isContinuation, isFalse);
      final firstSpanP2 = doc.pages[1].first;
      expect(firstSpanP2.blockIndex, 2);
      expect(firstSpanP2.startLine, 2);
      expect(firstSpanP2.endLine, 5);
      expect(firstSpanP2.isContinuation, isTrue);
    });

    test('respects widow=2 — would-be-1-line widow is bumped', () {
      // Single 11-line paragraph on a fresh 10-line page: greedy fill
      // would leave 1 widow line on next page; engine should pull
      // back to 9 + 2.
      final doc = PaginationEngine.paginate(
        blocks: [_para(11)],
        linesPerPage: 10,
      );
      expect(doc.pageCount, 2);
      final p1 = doc.pages[0].single;
      final p2 = doc.pages[1].single;
      expect(p1.lineCount, 9);
      expect(p2.lineCount, 2);
      expect(p2.isContinuation, isTrue);
    });

    test('respects orphan=2 — 1-line slack pushes block to next page', () {
      // Page already has 9 lines; 5-line paragraph would leave only
      // 1 line on current page — under orphan threshold. Should push
      // whole block to page 2.
      final doc = PaginationEngine.paginate(
        blocks: [_para(9), _para(5)],
        linesPerPage: 10,
      );
      expect(doc.pageCount, 2);
      expect(doc.pages[0].map((s) => s.blockIndex).toList(), [0]);
      expect(doc.pages[1].map((s) => s.blockIndex).toList(), [1]);
    });

    test('paragraph longer than a page splits multiple times', () {
      final doc = PaginationEngine.paginate(
        blocks: [_para(28)],
        linesPerPage: 10,
      );
      // 28 lines / 10 LPP, with widow=2 → 10 + 10 + 8 (last page
      // still ≥ widow). Three pages, each line range contiguous.
      expect(doc.pageCount, 3);
      final all = doc.pages.expand((p) => p).toList();
      expect(all.length, 3);
      expect(all.first.startLine, 0);
      expect(all.last.endLine, 28);
      // Per-page page limits hold.
      for (final s in all) {
        expect(s.lineCount, lessThanOrEqualTo(10));
      }
      // Every continuation flag is set after the first.
      expect(all.first.isContinuation, isFalse);
      expect(all.skip(1).every((s) => s.isContinuation), isTrue);
      // Reassembly is contiguous.
      var cursor = 0;
      for (final s in all) {
        expect(s.startLine, cursor);
        cursor = s.endLine;
      }
      expect(cursor, 28);
    });

    test('orphanMin=1 lets a 1-line stub remain on current page', () {
      // With the relaxed rule, the engine should split the 5-line
      // paragraph at line 1 instead of pushing the whole block down.
      final doc = PaginationEngine.paginate(
        blocks: [_para(9), _para(5)],
        linesPerPage: 10,
        orphanMin: 1,
        widowMin: 1,
      );
      expect(doc.pageCount, 2);
      expect(doc.pages[0].last.blockIndex, 1);
      expect(doc.pages[0].last.endLine, 1);
    });
  });

  group('PaginationEngine.paginate — keep-with-next (headings)', () {
    test('heading at end of page pushes to next page if follower would orphan', () {
      // Page already has 9 lines; heading is 1 line, follower is a
      // 5-line paragraph. Combined need = 1 + 2 (orphan) = 3 > 1
      // remaining → push heading to next page.
      final doc = PaginationEngine.paginate(
        blocks: [_para(9), _heading(1), _para(5)],
        linesPerPage: 10,
      );
      // Page 1: just the 9-line para.
      expect(doc.pages[0].map((s) => s.blockIndex), [0]);
      // Page 2: heading + paragraph.
      expect(doc.pages[1].map((s) => s.blockIndex), [1, 2]);
    });

    test('heading at end of page stays put when follower fits', () {
      // 7 lines used, 3 remaining. Heading + 2 lines (orphan) = 3
      // → fits exactly. Heading stays on page 1.
      final doc = PaginationEngine.paginate(
        blocks: [_para(7), _heading(1), _para(2)],
        linesPerPage: 10,
      );
      expect(doc.pageCount, 1);
      expect(doc.pages[0].length, 3);
    });

    test('heading without follower is treated as an unsplittable block', () {
      final doc = PaginationEngine.paginate(
        blocks: [_para(9), _heading(2)],
        linesPerPage: 10,
      );
      // 2-line heading on a page with 1 remaining → push to page 2.
      expect(doc.pageCount, 2);
      expect(doc.pages[0].map((s) => s.blockIndex), [0]);
      expect(doc.pages[1].map((s) => s.blockIndex), [1]);
    });

    test('heading + paragraph combined longer than a page still splits paragraph', () {
      final doc = PaginationEngine.paginate(
        blocks: [_heading(2), _para(20)],
        linesPerPage: 10,
      );
      // Heading (2) on page 1, then 8 lines of para → page 2 gets
      // remaining 12 lines split again: 10 then 2.
      expect(doc.pageCount, 3);
      expect(doc.pages[0].first.blockIndex, 0);
      // The split paragraph spans pages 1, 2, and 3.
      final paraSpans = doc.pages
          .expand((p) => p)
          .where((s) => s.blockIndex == 1)
          .toList();
      expect(paraSpans.length, 3);
      var cursor = 0;
      for (final s in paraSpans) {
        expect(s.startLine, cursor);
        cursor = s.endLine;
      }
      expect(cursor, 20);
    });
  });

  group('PaginationEngine.paginate — embeds (atomic blocks)', () {
    test('embed bumped to next page when it doesn\'t fit', () {
      final doc = PaginationEngine.paginate(
        blocks: [_para(7), _embed()],
        linesPerPage: 10,
      );
      // Page 1: para. Page 2: embed (whole, since 6 < 10).
      expect(doc.pageCount, 2);
      expect(doc.pages[1].single.blockIndex, 1);
      expect(doc.pages[1].single.lineCount, 6);
    });

    test('embed bigger than a page is force-split (degenerate)', () {
      // Build an unsplittable 14-line block to mimic a giant image.
      final huge = PageBlock(
        lines: 14,
        keepWithNext: false,
        splittable: false,
        headingLevel: 0,
        isList: false,
        isBlockquote: false,
        isEmbed: true,
      );
      final doc = PaginationEngine.paginate(
        blocks: [huge],
        linesPerPage: 10,
      );
      expect(doc.pageCount, 2);
      expect(doc.pages[0].single.lineCount, 10);
      expect(doc.pages[1].single.lineCount, 4);
    });
  });

  group('PaginationEngine.paginate — page lookup', () {
    test('pageForBlock returns 1-indexed page', () {
      final doc = PaginationEngine.paginate(
        blocks: [_para(5), _para(5), _para(5)],
        linesPerPage: 10,
      );
      expect(doc.pageForBlock(0), 1);
      expect(doc.pageForBlock(1), 1);
      expect(doc.pageForBlock(2), 2);
    });
  });

  group('PaginationEngine.blocksFromDelta — extraction', () {
    test('three plain paragraphs yield three blocks', () {
      final ops = [
        {'insert': 'First paragraph.\n'},
        {'insert': 'Second paragraph.\n'},
        {'insert': 'Third paragraph.\n'},
      ];
      final blocks = PaginationEngine.blocksFromDelta(
        ops,
        contentWidthPx: 600,
        bodyFontSizePx: 16,
      );
      expect(blocks.length, 3);
      expect(blocks.every((b) => !b.keepWithNext), isTrue);
      expect(blocks.every((b) => b.splittable), isTrue);
    });

    test('header attribute on the newline op marks the block as a heading', () {
      final ops = [
        {'insert': 'Chapter 1'},
        {'insert': '\n', 'attributes': {'header': 1}},
        {'insert': 'Body.\n'},
      ];
      final blocks = PaginationEngine.blocksFromDelta(
        ops,
        contentWidthPx: 600,
        bodyFontSizePx: 16,
      );
      expect(blocks.length, 2);
      expect(blocks[0].headingLevel, 1);
      expect(blocks[0].keepWithNext, isTrue);
      expect(blocks[0].splittable, isFalse);
      expect(blocks[1].keepWithNext, isFalse);
    });

    test('embed insert produces an unsplittable block', () {
      final ops = [
        {'insert': 'Before.\n'},
        {'insert': {'image': 'https://example.com/cat.png'}},
        {'insert': '\n'},
        {'insert': 'After.\n'},
      ];
      final blocks = PaginationEngine.blocksFromDelta(
        ops,
        contentWidthPx: 600,
        bodyFontSizePx: 16,
      );
      // text, embed, blank-line(after embed), text — the trailing
      // newline after the embed produces a 1-line empty paragraph.
      expect(blocks.length, 4);
      expect(blocks[1].isEmbed, isTrue);
      expect(blocks[1].splittable, isFalse);
    });

    test('blocksFromJsonString tolerates malformed JSON', () {
      final blocks = PaginationEngine.blocksFromJsonString(
        'not json at all',
        contentWidthPx: 600,
        bodyFontSizePx: 16,
      );
      // One fallback paragraph.
      expect(blocks.length, 1);
    });

    test('blocksFromJsonString round-trips a valid delta', () {
      final json = jsonEncode([
        {'insert': 'Hello world.\n'},
      ]);
      final blocks = PaginationEngine.blocksFromJsonString(
        json,
        contentWidthPx: 600,
        bodyFontSizePx: 16,
      );
      expect(blocks.length, 1);
      expect(blocks.first.lines, greaterThanOrEqualTo(1));
    });

    test('long paragraph spans multiple lines per estimator', () {
      final longText = 'word ' * 200; // ~1000 chars
      final ops = [
        {'insert': '$longText\n'},
      ];
      final blocks = PaginationEngine.blocksFromDelta(
        ops,
        contentWidthPx: 400,
        bodyFontSizePx: 16,
      );
      expect(blocks.length, 1);
      // 1000 chars / (400 / (16 * 0.5)) = 1000 / 50 = 20 lines.
      expect(blocks.first.lines, greaterThanOrEqualTo(15));
    });
  });

  group('PaginationEngine.paginate — invariants under random input', () {
    test('all line ranges remain contiguous and non-overlapping', () {
      final blocks = <PageBlock>[];
      // Mix of paras, headings, and embeds.
      for (var i = 0; i < 200; i++) {
        if (i % 17 == 0) {
          blocks.add(_heading(2));
        } else if (i % 23 == 0) {
          blocks.add(_embed());
        } else {
          blocks.add(_para(1 + (i % 11)));
        }
      }
      final doc = PaginationEngine.paginate(
        blocks: blocks,
        linesPerPage: 24,
      );
      // Reassembly: every block's spans should reconstruct the
      // original line count, with no gaps.
      final byBlock = <int, List<PageSpan>>{};
      for (final page in doc.pages) {
        for (final span in page) {
          byBlock.putIfAbsent(span.blockIndex, () => <PageSpan>[]).add(span);
        }
      }
      for (final entry in byBlock.entries) {
        final spans = entry.value;
        var cursor = 0;
        for (final s in spans) {
          expect(s.startLine, cursor,
              reason: 'gap in block ${entry.key}');
          cursor = s.endLine;
        }
        expect(cursor, blocks[entry.key].lines,
            reason: 'block ${entry.key} not fully covered');
      }
    });
  });
}
