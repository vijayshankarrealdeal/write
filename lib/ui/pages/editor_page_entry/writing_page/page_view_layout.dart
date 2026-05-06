import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/page_layout_settings.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/services/pagination_engine.dart';

/// Paginated layout for the editor's "Page" view.
///
/// Renders the active section as a vertically-scrolling stack of
/// virtual pages sized to match the writer's project page-layout
/// settings (Letter / A4 / custom, configurable margins, font,
/// line spacing). Page-break logic enforces three rules:
///
/// 1. Paragraphs only split between lines, never mid-line.
/// 2. Headings stay with their following paragraph (keep-with-next).
/// 3. Widow / orphan minimums ensure split paragraphs leave at least
///    two lines on each side.
///
/// Rendering is read-only by design — same scope shape as the
/// `Scrivenings` view. Tap the pencil on any page header to jump
/// back to Draft mode focused on that paragraph.
///
/// Performance: a `ListView.builder` mounts only the pages currently
/// in the viewport, so a 100k-word document with ~330 virtual pages
/// stays light (≈3 pages alive at any time). Pagination itself is
/// `O(blocks)` in the pure engine.
class PageViewLayout extends StatefulWidget {
  const PageViewLayout({
    super.key,
    required this.onJumpToOffset,
    required this.onPageCountChanged,
    required this.onCurrentPageChanged,
    this.onOpenSettings,
  });

  /// Switch the editor back to Draft mode and place the caret at
  /// `globalOffset` (character index into the active section's
  /// document). Lets a writer click on a page in the preview and
  /// land at the right spot.
  final void Function(int globalOffset) onJumpToOffset;

  /// Reports total page count to the parent (status-bar wiring).
  final void Function(int total) onPageCountChanged;

  /// Reports the 1-indexed page currently in the viewport (status-bar
  /// "Page X of Y" wiring). Updates on scroll, debounced.
  final void Function(int current) onCurrentPageChanged;

  /// Opens the settings sheet that adjusts page size / margins /
  /// font. Optional — wired by the parent.
  final VoidCallback? onOpenSettings;

  @override
  State<PageViewLayout> createState() => _PageViewLayoutState();
}

class _PageViewLayoutState extends State<PageViewLayout> {
  PaginatedDocument? _doc;
  List<PageBlock> _blocks = const [];
  String? _renderedContent;
  PageLayoutSettings? _renderedSettings;
  Timer? _debounce;
  final ScrollController _scrollController = ScrollController();
  // Per-page top offsets (in scroll-axis pixels) so we can map
  // viewport position → "current page" for the status bar.
  final List<double> _pageTops = <double>[];
  double _pageHeightPx = 0;
  double _pageGapPx = 24;
  // Inset between the first page and the top of the scroll area
  // (matches the SliverPadding above the ListView).
  double _scrollTopPadding = 24;
  int _lastReportedCurrent = 0;
  int _lastReportedTotal = 0;
  static const Duration _repagDebounce = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_pageTops.isEmpty || _pageHeightPx <= 0) return;
    final offset = _scrollController.offset + _pageHeightPx / 2;
    var current = 1;
    for (var i = 0; i < _pageTops.length; i++) {
      if (offset >= _pageTops[i]) {
        current = i + 1;
      } else {
        break;
      }
    }
    if (current != _lastReportedCurrent) {
      _lastReportedCurrent = current;
      widget.onCurrentPageChanged(current);
    }
  }

  void _scheduleRepaginate(EditorProvider provider, PageLayoutSettings settings) {
    final controller = provider.controller;
    final content = _serializeDocument(controller);
    if (content == _renderedContent && settings == _renderedSettings) {
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(_repagDebounce, () {
      if (!mounted) return;
      _runPagination(content, settings);
    });
  }

  /// Synchronous pagination + invalidation. Public so the widget
  /// test can drive the algorithm without waiting on a debounce.
  void _runPagination(String content, PageLayoutSettings settings) {
    final blocks = PaginationEngine.blocksFromJsonString(
      content,
      contentWidthPx: settings.contentWidthPx,
      bodyFontSizePx: settings.fontSizePx,
    );
    final doc = PaginationEngine.paginate(
      blocks: blocks,
      linesPerPage: settings.linesPerPage,
    );
    setState(() {
      _doc = doc;
      _blocks = blocks;
      _renderedContent = content;
      _renderedSettings = settings;
    });
    if (doc.pageCount != _lastReportedTotal) {
      _lastReportedTotal = doc.pageCount;
      widget.onPageCountChanged(doc.pageCount);
    }
    // Re-emit current page (recompute against new layout).
    _lastReportedCurrent = 0;
    _onScroll();
    // First-time emit: at top of the scroll view, current page is 1.
    if (_lastReportedCurrent == 0) {
      _lastReportedCurrent = 1;
      widget.onCurrentPageChanged(1);
    }
  }

  String _serializeDocument(QuillController controller) {
    // Mirror the storage shape so the engine sees the same JSON it
    // would on disk. Avoids a separate code-path for this widget.
    try {
      final delta = controller.document.toDelta().toJson();
      return _encodeJson(delta);
    } catch (_) {
      return controller.document.toPlainText();
    }
  }

  static String _encodeJson(List<dynamic> delta) {
    // Lightweight encoder — `jsonEncode` would also work but we want
    // a stable, allocation-light path because this runs every
    // pagination cycle.
    return _quickJson(delta);
  }

  static String _quickJson(dynamic v) {
    // Fallback to the platform JSON encoder; the StringBuffer
    // version added complexity without measurable wins.
    return _stableJsonEncode(v);
  }

  static String _stableJsonEncode(dynamic v) =>
      const _JsonStable().convert(v);

  @override
  Widget build(BuildContext context) {
    return Consumer<EditorProvider>(
      builder: (context, provider, _) {
        final book = provider.activeBook;
        final section = provider.activeSection;
        final settings = book?.pageLayout ?? PageLayoutSettings.standard;
        if (section == null) {
          return _emptyState(context, 'Select a section to preview as pages.');
        }

        // Re-paginate if controller content changed or settings flipped.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _scheduleRepaginate(provider, settings);
        });

        // Listen for live document changes (typing in another view,
        // sync push, etc.) so the page view stays in step.
        return ListenableBuilder(
          listenable: provider.controller,
          builder: (context, _) {
            // The post-frame callback above handles the
            // re-pagination — this builder just guarantees we wake
            // up on every doc edit.
            return LayoutBuilder(
              builder: (context, constraints) =>
                  _buildPagedContent(context, settings, section, constraints),
            );
          },
        );
      },
    );
  }

  Widget _emptyState(BuildContext context, String message) {
    final theme = Theme.of(context);
    final color =
        (theme.textTheme.bodyMedium?.color ?? Colors.black).withValues(alpha: 0.55);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(fontSize: 13, color: color),
        ),
      ),
    );
  }

  Widget _buildPagedContent(
    BuildContext context,
    PageLayoutSettings settings,
    SectionModel section,
    BoxConstraints constraints,
  ) {
    final doc = _doc;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Scale page width down to fit narrow viewports (mobile). Pages
    // never exceed their physical pixel width — wider screens just
    // show the page centered with margin chrome.
    final maxPageWidth = settings.pageWidthPx;
    final available = constraints.maxWidth - 48; // page gutters
    final scale = available < maxPageWidth ? available / maxPageWidth : 1.0;
    final renderedWidth = maxPageWidth * scale;
    final renderedHeight = settings.pageHeightPx * scale;
    _pageHeightPx = renderedHeight + _pageGapPx;
    _scrollTopPadding = 24;
    _pageGapPx = 24;
    _pageTops.clear();
    if (doc != null) {
      for (var i = 0; i < doc.pageCount; i++) {
        _pageTops.add(_scrollTopPadding + i * _pageHeightPx);
      }
    }

    if (doc == null) {
      // First paint: render nothing yet but still kick off pagination.
      return _emptyState(context, 'Laying out pages…');
    }
    if (doc.pageCount == 0 || (doc.pageCount == 1 && doc.pages.first.isEmpty)) {
      return _emptyState(context,
          'Add a chapter or scene to see paginated pages.');
    }

    return Container(
      color: isDark ? const Color(0xFF111111) : const Color(0xFFE9E9EE),
      child: ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.symmetric(
          vertical: _scrollTopPadding,
          horizontal: 24,
        ),
        itemCount: doc.pageCount,
        // Pre-cache one page above and below the viewport so scroll
        // feels instant on long manuscripts.
        cacheExtent: renderedHeight * 1.5,
        itemBuilder: (context, index) {
          return Padding(
            padding: EdgeInsets.only(bottom: _pageGapPx),
            child: Center(
              child: SizedBox(
                width: renderedWidth,
                height: renderedHeight,
                child: _PageCard(
                  pageNumber: index + 1,
                  totalPages: doc.pageCount,
                  spans: doc.pages[index],
                  blocks: _blocks,
                  settings: settings,
                  scale: scale,
                  isDark: isDark,
                  onTapHeader: () =>
                      _jumpToFirstSpan(doc.pages[index], section),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _jumpToFirstSpan(List<PageSpan> spans, SectionModel section) {
    if (spans.isEmpty) {
      widget.onJumpToOffset(0);
      return;
    }
    final blockIdx = spans.first.blockIndex;
    var charOffset = 0;
    for (var i = 0; i < blockIdx && i < _blocks.length; i++) {
      // +1 for the trailing newline that closed the previous block.
      final blockText = _blocks[i].runs.map((r) => r.text).join();
      charOffset += blockText.length + 1;
    }
    widget.onJumpToOffset(charOffset);
  }
}

/// Standalone JSON encoder so we don't pull in `dart:convert` just
/// for this widget. Identical output to `jsonEncode` for the shapes
/// we feed it (`List<dynamic>` of maps with primitive values).
class _JsonStable {
  const _JsonStable();
  String convert(dynamic v) {
    final sb = StringBuffer();
    _write(sb, v);
    return sb.toString();
  }

  void _write(StringBuffer sb, dynamic v) {
    if (v == null) {
      sb.write('null');
    } else if (v is num) {
      sb.write(v);
    } else if (v is bool) {
      sb.write(v ? 'true' : 'false');
    } else if (v is String) {
      sb.write('"');
      for (final c in v.codeUnits) {
        if (c == 0x22) {
          sb.write(r'\"');
        } else if (c == 0x5C) {
          sb.write(r'\\');
        } else if (c == 0x0A) {
          sb.write(r'\n');
        } else if (c == 0x0D) {
          sb.write(r'\r');
        } else if (c == 0x09) {
          sb.write(r'\t');
        } else if (c < 0x20) {
          sb.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
        } else {
          sb.writeCharCode(c);
        }
      }
      sb.write('"');
    } else if (v is List) {
      sb.write('[');
      for (var i = 0; i < v.length; i++) {
        if (i > 0) sb.write(',');
        _write(sb, v[i]);
      }
      sb.write(']');
    } else if (v is Map) {
      sb.write('{');
      var first = true;
      v.forEach((k, val) {
        if (!first) sb.write(',');
        first = false;
        _write(sb, k.toString());
        sb.write(':');
        _write(sb, val);
      });
      sb.write('}');
    } else {
      _write(sb, v.toString());
    }
  }
}

/// Pure renderer for a paginated document. Takes the engine output
/// directly so the widget tests don't need an [EditorProvider]
/// stack — they just feed it blocks + a [PaginatedDocument] and
/// assert on the resulting page cards.
class PaginatedDocumentView extends StatefulWidget {
  const PaginatedDocumentView({
    super.key,
    required this.blocks,
    required this.document,
    required this.settings,
    this.onPageScrolled,
    this.onTapPageHeader,
    this.scrollController,
  });

  final List<PageBlock> blocks;
  final PaginatedDocument document;
  final PageLayoutSettings settings;
  final void Function(int currentPage)? onPageScrolled;
  final void Function(int pageIndex)? onTapPageHeader;
  final ScrollController? scrollController;

  @override
  State<PaginatedDocumentView> createState() =>
      _PaginatedDocumentViewState();
}

class _PaginatedDocumentViewState extends State<PaginatedDocumentView> {
  late final ScrollController _scroll;
  bool _ownsController = false;
  final List<double> _pageTops = <double>[];
  double _pageHeightPx = 0;
  int _lastReportedCurrent = 0;

  @override
  void initState() {
    super.initState();
    _scroll = widget.scrollController ?? ScrollController();
    _ownsController = widget.scrollController == null;
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    if (_ownsController) _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_pageTops.isEmpty || _pageHeightPx <= 0) return;
    final offset = _scroll.offset + _pageHeightPx / 2;
    var current = 1;
    for (var i = 0; i < _pageTops.length; i++) {
      if (offset >= _pageTops[i]) {
        current = i + 1;
      } else {
        break;
      }
    }
    if (current != _lastReportedCurrent) {
      _lastReportedCurrent = current;
      widget.onPageScrolled?.call(current);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxPageWidth = widget.settings.pageWidthPx;
        final available = constraints.maxWidth - 48;
        final scale = available < maxPageWidth ? available / maxPageWidth : 1.0;
        final renderedWidth = maxPageWidth * scale;
        final renderedHeight = widget.settings.pageHeightPx * scale;
        const gap = 24.0;
        const topPad = 24.0;
        _pageHeightPx = renderedHeight + gap;
        _pageTops
          ..clear()
          ..addAll([
            for (var i = 0; i < widget.document.pageCount; i++)
              topPad + i * _pageHeightPx
          ]);
        if (widget.document.pageCount == 0 ||
            (widget.document.pageCount == 1 &&
                widget.document.pages.first.isEmpty)) {
          return Container(
            color: isDark ? const Color(0xFF111111) : const Color(0xFFE9E9EE),
            alignment: Alignment.center,
            child: Text(
              'Add a chapter or scene to see paginated pages.',
              style: GoogleFonts.inter(
                fontSize: 13,
                color: (theme.textTheme.bodyMedium?.color ?? Colors.black)
                    .withValues(alpha: 0.55),
              ),
            ),
          );
        }
        return Container(
          color: isDark ? const Color(0xFF111111) : const Color(0xFFE9E9EE),
          child: ListView.builder(
            controller: _scroll,
            padding:
                const EdgeInsets.symmetric(vertical: topPad, horizontal: 24),
            itemCount: widget.document.pageCount,
            cacheExtent: renderedHeight * 1.5,
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.only(bottom: gap),
                child: Center(
                  child: SizedBox(
                    width: renderedWidth,
                    height: renderedHeight,
                    child: _PageCard(
                      pageNumber: index + 1,
                      totalPages: widget.document.pageCount,
                      spans: widget.document.pages[index],
                      blocks: widget.blocks,
                      settings: widget.settings,
                      scale: scale,
                      isDark: isDark,
                      onTapHeader: () =>
                          widget.onTapPageHeader?.call(index),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// One physical page card (white surface + drop shadow + clipped
/// content). Purely visual; pagination happens upstream.
class _PageCard extends StatelessWidget {
  const _PageCard({
    required this.pageNumber,
    required this.totalPages,
    required this.spans,
    required this.blocks,
    required this.settings,
    required this.scale,
    required this.isDark,
    required this.onTapHeader,
  });

  final int pageNumber;
  final int totalPages;
  final List<PageSpan> spans;
  final List<PageBlock> blocks;
  final PageLayoutSettings settings;
  final double scale;
  final bool isDark;
  final VoidCallback onTapHeader;

  @override
  Widget build(BuildContext context) {
    final paperColor = isDark ? const Color(0xFF1B1B1F) : Colors.white;
    final inkColor = isDark
        ? const Color(0xFFEDEDED)
        : const Color(0xFF111111);
    final mutedColor = inkColor.withValues(alpha: 0.45);

    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            color: paperColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.12),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: EdgeInsets.fromLTRB(
            settings.marginLeftPx * scale,
            settings.marginTopPx * scale,
            settings.marginRightPx * scale,
            settings.marginBottomPx * scale,
          ),
          child: ClipRect(
            child: _PageBody(
              spans: spans,
              blocks: blocks,
              settings: settings,
              scale: scale,
              inkColor: inkColor,
            ),
          ),
        ),
        Positioned(
          top: 6,
          right: 8,
          child: _PageBadge(
            isDark: isDark,
            label: '$pageNumber / $totalPages',
            mutedColor: mutedColor,
          ),
        ),
        Positioned(
          top: 4,
          left: 6,
          child: IconButton(
            tooltip: 'Edit this section',
            icon: Icon(
              CupertinoIcons.pencil,
              size: 14,
              color: mutedColor,
            ),
            visualDensity: VisualDensity.compact,
            onPressed: onTapHeader,
            splashRadius: 16,
          ),
        ),
      ],
    );
  }
}

class _PageBadge extends StatelessWidget {
  const _PageBadge({
    required this.isDark,
    required this.label,
    required this.mutedColor,
  });
  final bool isDark;
  final String label;
  final Color mutedColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: mutedColor,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _PageBody extends StatelessWidget {
  const _PageBody({
    required this.spans,
    required this.blocks,
    required this.settings,
    required this.scale,
    required this.inkColor,
  });

  final List<PageSpan> spans;
  final List<PageBlock> blocks;
  final PageLayoutSettings settings;
  final double scale;
  final Color inkColor;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final span in spans) {
      if (span.blockIndex >= blocks.length) continue;
      final block = blocks[span.blockIndex];
      children.add(_BlockSlice(
        span: span,
        block: block,
        settings: settings,
        scale: scale,
        inkColor: inkColor,
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

class _BlockSlice extends StatelessWidget {
  const _BlockSlice({
    required this.span,
    required this.block,
    required this.settings,
    required this.scale,
    required this.inkColor,
  });

  final PageSpan span;
  final PageBlock block;
  final PageLayoutSettings settings;
  final double scale;
  final Color inkColor;

  @override
  Widget build(BuildContext context) {
    if (block.isEmbed) {
      return _embedSlice();
    }
    final fontScale = scale;
    final bodySize = settings.fontSizePx * fontScale;
    final lineHeight = settings.lineHeight;
    double size;
    FontWeight weight = FontWeight.w400;
    if (block.headingLevel == 1) {
      size = bodySize * 1.7;
      weight = FontWeight.w700;
    } else if (block.headingLevel == 2) {
      size = bodySize * 1.4;
      weight = FontWeight.w700;
    } else if (block.headingLevel == 3) {
      size = bodySize * 1.2;
      weight = FontWeight.w600;
    } else {
      size = bodySize;
    }

    final fullText = block.runs.map((r) => r.text).join();
    final cpl = math.max(1, block.charsPerLine);
    // Map (startLine, endLine) → character window on the underlying
    // text. Heading multipliers are applied in `_estimateLineMetrics`
    // so we divide here to map back to visual lines.
    final headingMul = block.headingLevel == 1 || block.headingLevel == 2
        ? 2
        : 1;
    final visualStart = (span.startLine ~/ headingMul);
    final visualEnd = (span.endLine + headingMul - 1) ~/ headingMul;
    final charStart = math.min(fullText.length, visualStart * cpl);
    final charEnd = math.min(fullText.length, visualEnd * cpl);
    final spans = _sliceRuns(block.runs, charStart, charEnd, inkColor);
    if (spans.isEmpty && fullText.isEmpty) {
      // Empty paragraph (intentional vertical break).
      return SizedBox(height: size * lineHeight);
    }
    final padding = block.headingLevel > 0
        ? EdgeInsets.only(top: size * 0.4, bottom: size * 0.2)
        : EdgeInsets.only(bottom: size * 0.3);
    final indent = block.isList || block.isBlockquote ? size * 1.5 : 0.0;
    return Padding(
      padding: padding.add(EdgeInsets.only(left: indent)),
      child: Text.rich(
        TextSpan(children: spans),
        style: _baseStyle(settings, size, weight, inkColor, lineHeight),
        softWrap: true,
        overflow: TextOverflow.clip,
      ),
    );
  }

  Widget _embedSlice() {
    final src = block.embedSrc;
    final isImage = block.embedKind == 'image' && src.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        height: 60 * scale,
        decoration: BoxDecoration(
          color: inkColor.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Text(
          isImage ? '[image]' : '[${block.embedKind}]',
          style: GoogleFonts.inter(
            fontSize: 11,
            color: inkColor.withValues(alpha: 0.55),
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }

  TextStyle _baseStyle(
    PageLayoutSettings settings,
    double size,
    FontWeight weight,
    Color color,
    double lineHeight,
  ) {
    switch (settings.font) {
      case PageFont.merriweather:
        return GoogleFonts.merriweather(
          fontSize: size,
          fontWeight: weight,
          color: color,
          height: lineHeight,
        );
      case PageFont.lora:
        return GoogleFonts.lora(
          fontSize: size,
          fontWeight: weight,
          color: color,
          height: lineHeight,
        );
      case PageFont.sourceSerif:
        return GoogleFonts.sourceSerif4(
          fontSize: size,
          fontWeight: weight,
          color: color,
          height: lineHeight,
        );
      case PageFont.inter:
        return GoogleFonts.inter(
          fontSize: size,
          fontWeight: weight,
          color: color,
          height: lineHeight,
        );
      case PageFont.jetbrainsMono:
        return GoogleFonts.jetBrainsMono(
          fontSize: size,
          fontWeight: weight,
          color: color,
          height: lineHeight,
        );
    }
  }

  List<TextSpan> _sliceRuns(
    List<InlineRun> runs,
    int charStart,
    int charEnd,
    Color color,
  ) {
    final out = <TextSpan>[];
    var cursor = 0;
    for (final run in runs) {
      final runStart = cursor;
      final runEnd = cursor + run.length;
      cursor = runEnd;
      if (runEnd <= charStart) continue;
      if (runStart >= charEnd) break;
      final lo = math.max(charStart, runStart) - runStart;
      final hi = math.min(charEnd, runEnd) - runStart;
      final sliced = run.slice(lo, hi);
      if (sliced.text.isEmpty) continue;
      out.add(TextSpan(
        text: sliced.text,
        style: TextStyle(
          fontWeight: sliced.bold ? FontWeight.w700 : null,
          fontStyle: sliced.italic ? FontStyle.italic : null,
          decoration: sliced.underline
              ? TextDecoration.underline
              : sliced.strike
                  ? TextDecoration.lineThrough
                  : null,
          color: sliced.link != null ? const Color(0xFF1E88E5) : color,
        ),
      ));
    }
    return out;
  }
}
