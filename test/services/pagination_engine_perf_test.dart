/// Performance benchmark for the pagination engine.
///
/// The P2 #8 acceptance bar:
///   "performance must remain smooth on 100k-word documents …
///    100k words renders in <500ms initial paint."
///
/// "Initial paint" for the engine is the work that runs *before*
/// the first frame: parse the Quill delta into [PageBlock]s and
/// run [PaginationEngine.paginate]. Mounting individual page
/// widgets is amortised across the user's scroll via
/// [ListView.builder], so the engine pass is the only blocking
/// chunk.
///
/// We measure this end-to-end (delta → blocks → paginate) on a
/// synthetic 100,000-word manuscript and assert the budget. If a
/// future change regresses the engine the benchmark will fail
/// before it lands in CI.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/models/page_layout_settings.dart';
import 'package:inkspacex/services/pagination_engine.dart';

String _buildManuscript({
  required int targetWords,
  required int wordsPerParagraph,
  required int paragraphsPerChapter,
}) {
  final ops = <Map<String, dynamic>>[];
  var wordsWritten = 0;
  var chapterIdx = 1;
  // Reusable lorem-ipsum sentence kernel — keeps the build fast.
  const sentence =
      'It was the best of times it was the worst of times it was the age '
      'of wisdom it was the age of foolishness it was the epoch of belief '
      'it was the epoch of incredulity it was the season of light it was '
      'the season of darkness it was the spring of hope it was the winter '
      'of despair we had everything before us we had nothing before us. ';
  while (wordsWritten < targetWords) {
    // Chapter heading every paragraphsPerChapter paragraphs.
    if (chapterIdx == 1 ||
        wordsWritten ~/ (wordsPerParagraph * paragraphsPerChapter) >=
            chapterIdx) {
      ops.add({'insert': 'Chapter ${chapterIdx.toString().padLeft(2, "0")}'});
      ops.add({
        'insert': '\n',
        'attributes': {'header': 1},
      });
      chapterIdx += 1;
    }
    final wordsThisPara = wordsPerParagraph;
    // Tile sentences until we reach approx wordsThisPara words.
    final sb = StringBuffer();
    var paraWords = 0;
    while (paraWords < wordsThisPara) {
      sb.write(sentence);
      paraWords += sentence.split(' ').length - 1;
    }
    ops.add({'insert': sb.toString()});
    ops.add({'insert': '\n'});
    wordsWritten += paraWords;
  }
  return jsonEncode(ops);
}

void main() {
  test(
      'PaginationEngine extracts + paginates a 100k-word manuscript in <500ms',
      () {
    final manuscript = _buildManuscript(
      targetWords: 100000,
      wordsPerParagraph: 35,
      paragraphsPerChapter: 25,
    );
    final settings = PageLayoutSettings.standard;
    final stopwatch = Stopwatch()..start();
    final blocks = PaginationEngine.blocksFromJsonString(
      manuscript,
      contentWidthPx: settings.contentWidthPx,
      bodyFontSizePx: settings.fontSizePx,
    );
    final doc = PaginationEngine.paginate(
      blocks: blocks,
      linesPerPage: settings.linesPerPage,
    );
    stopwatch.stop();
    // Sanity: the manuscript was big enough to produce many blocks
    // and many pages, so we know the timer was actually exercised.
    expect(blocks.length, greaterThan(1000));
    expect(doc.pageCount, greaterThan(150));
    // Acceptance bar: under 500ms for the whole engine pass.
    final ms = stopwatch.elapsedMilliseconds;
    // Print so the benchmark is visible in CI logs even when it
    // passes — useful for tracking long-term drift.
    // ignore: avoid_print
    print(
      '[bench] 100k-word pagination: '
      '${blocks.length} blocks → ${doc.pageCount} pages in ${ms}ms',
    );
    expect(
      ms,
      lessThan(500),
      reason: 'pagination engine regressed; budget is 500ms for 100k words',
    );
  });

  test(
      'subsequent pagination calls are at least as fast (no global cache leak)',
      () {
    // Run 5 small docs back-to-back; each must be way under the
    // budget. Catches a regression that would only show up after
    // long sessions.
    final manuscript = _buildManuscript(
      targetWords: 5000,
      wordsPerParagraph: 30,
      paragraphsPerChapter: 20,
    );
    final settings = PageLayoutSettings.standard;
    for (var i = 0; i < 5; i++) {
      final sw = Stopwatch()..start();
      final blocks = PaginationEngine.blocksFromJsonString(
        manuscript,
        contentWidthPx: settings.contentWidthPx,
        bodyFontSizePx: settings.fontSizePx,
      );
      final doc = PaginationEngine.paginate(
        blocks: blocks,
        linesPerPage: settings.linesPerPage,
      );
      sw.stop();
      expect(doc.pageCount, greaterThan(0));
      expect(sw.elapsedMilliseconds, lessThan(150),
          reason: '5k-word run #$i too slow (${sw.elapsedMilliseconds}ms)');
    }
  });
}
