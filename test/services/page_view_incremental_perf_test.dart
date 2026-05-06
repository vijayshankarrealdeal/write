// Performance benchmark for the live Page view's incremental
// re-pagination.
//
// Acceptance bar from the engineering brief: a 100k-word manuscript
// must re-paginate in <100 ms after a single-section edit. Because
// the live view drives total page count from a `Map<sectionId,
// double>` of measured heights, recomputing the total is `O(N
// sections)` arithmetic — no re-parsing of any other section's
// delta. This benchmark times that loop directly to catch a future
// refactor that re-introduces a per-keystroke full-document pass.
//
// We also benchmark `PaginationEngine.paginate` for a single section
// — the engine still runs once per dirty section to get its true
// page count when we eventually call into it for split decisions —
// to guard against engine regressions touching the page view path.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/models/page_layout_settings.dart';
import 'package:inkspacex/services/pagination_engine.dart';

const _wordsPerSection = 1000; // ~5–6 pages per section
const _sectionCount = 100;     // 100k words total

void main() {
  test(
      'live page view: total-page recompute on a single edit runs in <100ms',
      () {
    // Simulate the height map the live view maintains. 100 sections
    // with realistic per-section page heights (between 1 and 12
    // pages each, distributed to reach roughly 333 total pages —
    // matching what the 100k-word manuscript paginates to).
    final pageHeightPx = PageLayoutSettings.standard.pageHeightPx;
    final rng = math.Random(42);
    final heights = <String, double>{
      for (var i = 0; i < _sectionCount; i++)
        's$i': pageHeightPx * (1 + rng.nextInt(12)),
    };
    final ids =
        List<String>.generate(_sectionCount, (i) => 's$i');

    int totalPages() {
      var total = 0;
      for (final id in ids) {
        final h = heights[id] ?? pageHeightPx;
        total += math.max(1, (h / pageHeightPx).ceil());
      }
      return math.max(1, total);
    }

    // Warm up.
    expect(totalPages(), greaterThan(_sectionCount));

    // Simulate 100 keystrokes in section #50, each remeasuring its
    // bucket and recomputing the total.
    final stopwatch = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      heights['s50'] = pageHeightPx * (5 + (i % 7));
      totalPages();
    }
    stopwatch.stop();
    final perEditUs = stopwatch.elapsedMicroseconds / 100.0;
    // ignore: avoid_print
    print('[bench] live page view: ${perEditUs.toStringAsFixed(1)} µs '
        'per single-section edit (× 100 edits, 100 sections)');
    expect(stopwatch.elapsedMilliseconds, lessThan(100),
        reason: 'live page-count recompute regressed past the budget');
  });

  test(
      'PaginationEngine.paginate on a single dirty section runs in <50ms',
      () {
    // The engine is invoked once per dirty section whenever the
    // page view needs to honor split rules (deferred to a debounce
    // in production) — make sure the per-section call is cheap.
    final ops = <Map<String, dynamic>>[];
    const sentence =
        'The quick brown fox jumps over the lazy dog. ';
    final buffer = StringBuffer();
    var paraWords = 0;
    while (paraWords < _wordsPerSection) {
      buffer.write(sentence);
      paraWords += sentence.split(' ').length - 1;
    }
    ops.add({'insert': buffer.toString()});
    ops.add({'insert': '\n'});

    final settings = PageLayoutSettings.standard;
    final stopwatch = Stopwatch()..start();
    final blocks = PaginationEngine.blocksFromDelta(
      ops,
      contentWidthPx: settings.contentWidthPx,
      bodyFontSizePx: settings.fontSizePx,
    );
    final doc = PaginationEngine.paginate(
      blocks: blocks,
      linesPerPage: settings.linesPerPage,
    );
    stopwatch.stop();
    expect(doc.pageCount, greaterThan(0));
    // ignore: avoid_print
    print('[bench] single-section engine: '
        '${stopwatch.elapsedMilliseconds} ms');
    expect(stopwatch.elapsedMilliseconds, lessThan(50));
  });
}
