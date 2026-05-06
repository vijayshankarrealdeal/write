import 'dart:convert';
import 'dart:math' as math;

/// Pure page-break algorithm for the editor's paginated view.
///
/// The engine takes a sequence of [PageBlock]s — each one already
/// flattened into a logical-line count — and produces a list of pages,
/// where each page is a list of [PageSpan]s pointing back at the
/// original blocks.
///
/// Why this lives in its own pure file: it's the core that needs unit
/// tests for the widow / orphan / keep-with-next rules, and the
/// performance benchmark (100k words → ~3,000 paragraphs → ~330
/// pages). Decoupling layout from rendering means tests don't need
/// Flutter widget plumbing.
class PaginationEngine {
  /// Default minimum lines that may stay on the *next* page when a
  /// paragraph is split. "Widow" in typesetting parlance.
  static const int defaultWidowMin = 2;

  /// Default minimum lines that must stay on the *current* page when
  /// a paragraph is split. "Orphan" in typesetting parlance.
  static const int defaultOrphanMin = 2;

  /// Run pagination over [blocks].
  ///
  /// [linesPerPage] is the integer line capacity of one page (already
  /// computed from physical page height ÷ line height in
  /// [PageLayoutSettings]).
  ///
  /// [widowMin] / [orphanMin] enforce the widow & orphan rules. Pass
  /// `1` to effectively disable them (any 1-line stub is allowed).
  static PaginatedDocument paginate({
    required List<PageBlock> blocks,
    required int linesPerPage,
    int widowMin = defaultWidowMin,
    int orphanMin = defaultOrphanMin,
  }) {
    assert(linesPerPage > 0, 'linesPerPage must be > 0');
    assert(widowMin >= 1, 'widowMin must be >= 1');
    assert(orphanMin >= 1, 'orphanMin must be >= 1');

    if (blocks.isEmpty) {
      return PaginatedDocument(pages: const [<PageSpan>[]]);
    }

    final pages = <List<PageSpan>>[];
    var current = <PageSpan>[];
    var remaining = linesPerPage;

    void flushPage() {
      pages.add(current);
      current = <PageSpan>[];
      remaining = linesPerPage;
    }

    var i = 0;
    var blockOffset = 0;
    var safetyCounter = 0;
    final safetyMax = blocks.length * 8 + linesPerPage * 4 + 64;

    while (i < blocks.length) {
      // Defensive guard: every iteration should either advance `i`,
      // advance `blockOffset` past 0, or shrink `remaining`. The bound
      // is generous; if we ever blow it we'd rather break than spin.
      if (safetyCounter++ > safetyMax) {
        assert(false, 'pagination loop exceeded safety bound');
        break;
      }

      final block = blocks[i];
      final remainingLines = block.lines - blockOffset;

      // Skip zero-line blocks (defensive — extractor filters them).
      if (remainingLines <= 0) {
        i++;
        blockOffset = 0;
        continue;
      }

      // ── Heading "keep-with-next" ────────────────────────────────
      // When a heading is starting fresh on a *partially-filled*
      // page, push it to a new page if the heading + at least
      // orphanMin lines of the following paragraph won't fit. This
      // prevents an "orphan heading" at the bottom of a page.
      if (block.keepWithNext &&
          blockOffset == 0 &&
          current.isNotEmpty &&
          i + 1 < blocks.length) {
        final next = blocks[i + 1];
        // Only enforce keep-with-next if the follower is itself big
        // enough to deserve `orphanMin` lines (skip for 1-line
        // sub-headings followed by another 1-line sub-heading).
        final followerWanted = math.min(next.lines, orphanMin);
        if (remainingLines + followerWanted > remaining) {
          flushPage();
          continue;
        }
      }

      // ── Whole block fits ────────────────────────────────────────
      if (remainingLines <= remaining) {
        current.add(PageSpan(
          blockIndex: i,
          startLine: blockOffset,
          endLine: blockOffset + remainingLines,
          isContinuation: blockOffset > 0,
        ));
        remaining -= remainingLines;
        i++;
        blockOffset = 0;
        if (remaining == 0 && i < blocks.length) flushPage();
        continue;
      }

      // ── Block doesn't fit ──────────────────────────────────────
      if (!block.splittable) {
        if (current.isNotEmpty) {
          flushPage();
          continue;
        }
        // Fresh page already; an unsplittable block bigger than a
        // page is a degenerate case (giant image embed). Force-place
        // what fits and split the remainder; the rendering layer
        // will treat split unsplittable spans as "first chunk shows
        // the embed, rest is empty" — acceptable fallback.
        final placed = math.min(remainingLines, linesPerPage);
        current.add(PageSpan(
          blockIndex: i,
          startLine: blockOffset,
          endLine: blockOffset + placed,
          isContinuation: blockOffset > 0,
        ));
        blockOffset += placed;
        if (blockOffset >= block.lines) {
          i++;
          blockOffset = 0;
        }
        flushPage();
        continue;
      }

      // ── Splittable paragraph ───────────────────────────────────
      // Try to honour widow + orphan: place [orphanMin .. remaining]
      // lines here, leaving the rest on the next page where it
      // must be ≥ widowMin.
      final maxOnCurrent = math.min(remaining, remainingLines - widowMin);
      if (maxOnCurrent >= orphanMin) {
        current.add(PageSpan(
          blockIndex: i,
          startLine: blockOffset,
          endLine: blockOffset + maxOnCurrent,
          isContinuation: blockOffset > 0,
        ));
        blockOffset += maxOnCurrent;
        flushPage();
        continue;
      }

      // ── Can't honour widow/orphan on current page ──────────────
      // If the current page has already been written to, push the
      // whole block to a fresh page and retry with `remaining =
      // linesPerPage`. This happens when only 1 line of slack
      // remains at the bottom (would be an orphan).
      if (current.isNotEmpty) {
        flushPage();
        continue;
      }

      // Fresh page already; the block is bigger than a single page
      // (`remainingLines > linesPerPage`). Split greedily — fill the
      // page, but back off so the next page gets ≥ widowMin lines.
      final maxIfSolo = remainingLines - widowMin;
      var placed = math.min(linesPerPage, maxIfSolo);
      if (placed < orphanMin) placed = math.min(remainingLines, linesPerPage);
      current.add(PageSpan(
        blockIndex: i,
        startLine: blockOffset,
        endLine: blockOffset + placed,
        isContinuation: blockOffset > 0,
      ));
      blockOffset += placed;
      remaining -= placed;
      if (blockOffset >= block.lines) {
        i++;
        blockOffset = 0;
      }
      if (remaining <= 0) flushPage();
    }

    if (current.isNotEmpty) {
      pages.add(current);
    }
    if (pages.isEmpty) {
      pages.add(<PageSpan>[]);
    }

    return PaginatedDocument(pages: pages);
  }

  /// Convert a Quill Delta (already-decoded JSON list of ops) into
  /// pagination blocks. Splits on '\n', treats embeds as 1-line
  /// blocks, and reads paragraph-level attributes (header, list,
  /// blockquote) off the trailing newline op.
  ///
  /// [contentWidthPx] and [bodyFontSizePx] feed the line-count
  /// estimator. The estimator is intentionally fast & approximate —
  /// pagination doesn't need pixel-exact reflow.
  static List<PageBlock> blocksFromDelta(
    List<dynamic> ops, {
    required double contentWidthPx,
    required double bodyFontSizePx,
  }) {
    final out = <PageBlock>[];
    final pendingRuns = <InlineRun>[];
    Map<String, dynamic>? lastNewlineAttrs;

    String currentBufferText() =>
        pendingRuns.map((r) => r.text).join();

    void flush({Map<String, dynamic>? attrs}) {
      final text = currentBufferText();
      final runs = List<InlineRun>.unmodifiable(pendingRuns);
      pendingRuns.clear();
      final parAttrs = attrs ?? lastNewlineAttrs;
      final headerLevel = (parAttrs?['header'] as num?)?.toInt() ?? 0;
      final isHeading = headerLevel > 0;
      final isList = parAttrs?['list'] != null;
      final isBlockquote = parAttrs?['blockquote'] == true;
      // Allow blank paragraphs (whitespace-only) — they're real
      // line breaks and consume vertical space — but skip
      // truly-empty (zero-length) blocks unless they're explicit
      // formatting.
      if (text.isEmpty && !isHeading && !isList && !isBlockquote) {
        // A bare \n still represents a paragraph break: count it
        // as one logical empty line so the writer's vertical
        // rhythm is preserved.
        out.add(PageBlock(
          lines: 1,
          keepWithNext: false,
          splittable: true,
          headingLevel: 0,
          isList: false,
          isBlockquote: false,
          runs: const <InlineRun>[],
        ));
        return;
      }
      final estimated = _estimateLineMetrics(
        text: text,
        contentWidthPx: contentWidthPx,
        bodyFontSizePx: bodyFontSizePx,
        headingLevel: headerLevel,
        isList: isList,
        isBlockquote: isBlockquote,
      );
      out.add(PageBlock(
        lines: estimated.lines,
        keepWithNext: isHeading,
        splittable: !isHeading,
        headingLevel: headerLevel,
        isList: isList,
        isBlockquote: isBlockquote,
        charsPerLine: estimated.charsPerLine,
        runs: runs,
      ));
    }

    for (final op in ops) {
      if (op is! Map) continue;
      final data = op['insert'];
      final attrs = op['attributes'] is Map
          ? Map<String, dynamic>.from(op['attributes'] as Map)
          : null;
      if (data is String) {
        // Walk the string segment-by-segment, splitting on '\n'.
        final parts = data.split('\n');
        for (var s = 0; s < parts.length; s++) {
          if (parts[s].isNotEmpty) {
            pendingRuns.add(_runFromAttrs(parts[s], attrs));
          }
          if (s < parts.length - 1) {
            // Each '\n' means: close the current paragraph using
            // the attributes attached to this op (Quill puts
            // paragraph-level attrs on the newline op). The '\n'
            // is consumed; subsequent text starts a new buffer.
            lastNewlineAttrs = attrs;
            flush(attrs: attrs);
          }
        }
      } else if (data is Map) {
        // Flush any pending text first, then add the embed as a
        // standalone line.
        if (pendingRuns.isNotEmpty) {
          flush();
        }
        final embedKind = data.keys.isNotEmpty ? data.keys.first.toString() : '';
        final embedSrc = embedKind.isEmpty ? '' : data[embedKind].toString();
        out.add(PageBlock(
          lines: 2,
          keepWithNext: false,
          splittable: false,
          headingLevel: 0,
          isList: false,
          isBlockquote: false,
          isEmbed: true,
          embedKind: embedKind,
          embedSrc: embedSrc,
        ));
      }
    }
    if (pendingRuns.isNotEmpty) {
      flush();
    }

    return out;
  }

  static InlineRun _runFromAttrs(
    String text,
    Map<String, dynamic>? attrs,
  ) {
    if (attrs == null || attrs.isEmpty) return InlineRun(text: text);
    return InlineRun(
      text: text,
      bold: attrs['bold'] == true,
      italic: attrs['italic'] == true,
      underline: attrs['underline'] == true,
      strike: attrs['strike'] == true,
      code: attrs['code'] == true,
      link: attrs['link'] is String ? attrs['link'] as String : null,
    );
  }

  /// Convenience: decode a stored Quill JSON string and run the
  /// extractor. Bad JSON returns an empty list — the editor surface
  /// will show "no content" instead of crashing.
  static List<PageBlock> blocksFromJsonString(
    String jsonStr, {
    required double contentWidthPx,
    required double bodyFontSizePx,
  }) {
    final trimmed = jsonStr.trim();
    if (trimmed.isEmpty) return const [];
    try {
      final parsed = jsonDecode(trimmed);
      if (parsed is List) {
        return blocksFromDelta(
          parsed,
          contentWidthPx: contentWidthPx,
          bodyFontSizePx: bodyFontSizePx,
        );
      }
      // Plain-text fallback: treat the whole thing as one
      // paragraph.
      return blocksFromDelta(
        [
          {'insert': trimmed},
          {'insert': '\n'},
        ],
        contentWidthPx: contentWidthPx,
        bodyFontSizePx: bodyFontSizePx,
      );
    } catch (_) {
      return blocksFromDelta(
        [
          {'insert': trimmed},
          {'insert': '\n'},
        ],
        contentWidthPx: contentWidthPx,
        bodyFontSizePx: bodyFontSizePx,
      );
    }
  }

  /// Estimate the rendered line metrics for a paragraph.
  ///
  /// Uses an average-character-width heuristic instead of a real
  /// `TextPainter.layout` call — the engine is on the hot path for
  /// every keystroke in the page view, and the algorithm itself
  /// handles approximate counts gracefully (off-by-one rarely shifts
  /// a page boundary).
  ///
  /// Headings use a larger font (and contribute ~1.4–2× the line
  /// height of body text); we account for that here so the pure
  /// engine doesn't need separate "heading-line" units.
  ///
  /// The same estimator is used at render time to slice a paragraph
  /// at line N — the renderer multiplies `charsPerLine` by the line
  /// index to find an approximate substring boundary.
  static ({int lines, int charsPerLine}) _estimateLineMetrics({
    required String text,
    required double contentWidthPx,
    required double bodyFontSizePx,
    required int headingLevel,
    required bool isList,
    required bool isBlockquote,
  }) {
    if (text.isEmpty) return (lines: 1, charsPerLine: 80);
    final fontSize = headingLevel == 1
        ? bodyFontSizePx * 1.7
        : headingLevel == 2
            ? bodyFontSizePx * 1.4
            : headingLevel == 3
                ? bodyFontSizePx * 1.2
                : bodyFontSizePx;
    // Average glyph width for proportional Latin text ≈ 0.5 × font
    // size. Conservative — biases toward more lines, which means
    // pagination prefers slightly-shorter pages over overflow.
    final avgCharPx = fontSize * 0.5;
    var effectiveWidth = contentWidthPx;
    if (isBlockquote) effectiveWidth -= bodyFontSizePx * 1.5;
    if (isList) effectiveWidth -= bodyFontSizePx * 1.5;
    if (effectiveWidth < bodyFontSizePx) effectiveWidth = bodyFontSizePx;
    final charsPerLine = math.max(1, (effectiveWidth / avgCharPx).floor());
    final visualLines = math.max(1, (text.length / charsPerLine).ceil());
    // Convert visual lines into "body line height" units so the
    // pure engine can operate on a single scale. Headings need
    // proportionally more vertical room.
    final lineMultiplier = headingLevel == 1
        ? 2
        : headingLevel == 2
            ? 2
            : headingLevel == 3
                ? 1
                : 1;
    return (
      lines: visualLines * lineMultiplier,
      charsPerLine: charsPerLine,
    );
  }
}

/// One paragraph (or embed) for the pure pagination algorithm.
///
/// The engine doesn't care about text — it only needs to know how
/// many logical lines the block consumes, whether it's "atomic"
/// (e.g. an image), and whether the block requests "keep with next"
/// behaviour (headings).
///
/// `runs` is optional and lets the renderer reuse the parsed inline
/// styling without re-walking the delta. Pagination math ignores it.
class PageBlock {
  final int lines;
  final bool keepWithNext;
  final bool splittable;
  final int headingLevel;
  final bool isList;
  final bool isBlockquote;
  final bool isEmbed;
  final int charsPerLine;
  final List<InlineRun> runs;
  final String embedKind;
  final String embedSrc;

  const PageBlock({
    required this.lines,
    required this.keepWithNext,
    required this.splittable,
    required this.headingLevel,
    required this.isList,
    required this.isBlockquote,
    this.isEmbed = false,
    this.charsPerLine = 80,
    this.runs = const <InlineRun>[],
    this.embedKind = '',
    this.embedSrc = '',
  });
}

/// A run of inline text with the (already-resolved) style attributes
/// from the source delta. The page renderer maps these straight into
/// `TextSpan`s.
class InlineRun {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final String? link;
  final bool code;

  const InlineRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.link,
    this.code = false,
  });

  InlineRun slice(int start, int end) {
    final lo = start < 0 ? 0 : start;
    final hi = end > text.length ? text.length : end;
    if (lo >= hi) {
      return InlineRun(
        text: '',
        bold: bold,
        italic: italic,
        underline: underline,
        strike: strike,
        link: link,
        code: code,
      );
    }
    return InlineRun(
      text: text.substring(lo, hi),
      bold: bold,
      italic: italic,
      underline: underline,
      strike: strike,
      link: link,
      code: code,
    );
  }

  int get length => text.length;
}

/// One contiguous run of lines from a single block, placed on a
/// specific page. `startLine` / `endLine` are line indices into the
/// owning block (inclusive / exclusive).
class PageSpan {
  final int blockIndex;
  final int startLine;
  final int endLine;
  final bool isContinuation;

  const PageSpan({
    required this.blockIndex,
    required this.startLine,
    required this.endLine,
    required this.isContinuation,
  });

  int get lineCount => endLine - startLine;

  @override
  String toString() => 'PageSpan(block=$blockIndex, lines=$startLine..$endLine'
      '${isContinuation ? ', cont' : ''})';
}

/// Output of [PaginationEngine.paginate]. Wraps the per-page span
/// list and exposes a few convenience getters.
class PaginatedDocument {
  final List<List<PageSpan>> pages;

  const PaginatedDocument({required this.pages});

  int get pageCount => pages.length;

  /// Total lines across every page; useful for benchmarks /
  /// regression tests.
  int get totalLines {
    var n = 0;
    for (final p in pages) {
      for (final s in p) {
        n += s.lineCount;
      }
    }
    return n;
  }

  /// Return the 1-indexed page number that contains the [blockIndex]th
  /// block (first occurrence). Returns 1 for empty docs.
  int pageForBlock(int blockIndex) {
    for (var i = 0; i < pages.length; i++) {
      for (final span in pages[i]) {
        if (span.blockIndex == blockIndex) return i + 1;
      }
    }
    return 1;
  }
}
