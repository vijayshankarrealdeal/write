import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/page_layout_settings.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/services/multi_section_editing_session.dart';

/// Live paginated editor view ("Page" mode, ⌘5).
///
/// Each publishable section is rendered as its own page-shaped card —
/// the card is at least one configured page tall (Letter, A4, custom),
/// uses the configured font / size / line spacing, and is live-editable
/// through the shared [MultiSectionEditingSession]. When a section's
/// content overflows a single page, dashed horizontal page-break
/// dividers appear inside the card at every page-height interval, each
/// labelled with its absolute page number.
///
/// Cursor preservation
/// -------------------
/// The session owns one [QuillController] per section, so the cursor /
/// undo stack / selection are kept across rebuilds. Switching to
/// Scrivenings or Draft and back returns the user to exactly where they
/// were because the session survives the swap (the provider only
/// disposes it when leaving multi-section mode entirely).
///
/// Live page-count
/// ---------------
/// Every section card measures its rendered height after layout (via a
/// `RenderObject` callback) and reports it back to the parent. Total
/// pages = `Σ ceil(sectionHeight / pageHeight)`; current page is
/// computed from the viewport center against the cumulative section
/// offsets. Both update incrementally on every keystroke — only the
/// edited section recomputes its row.
///
/// Performance
/// -----------
/// Sections mount lazily through `ListView.builder` (cacheExtent ≈ one
/// page above + below). On a 100k-word manuscript the in-flight page
/// computation is `O(sections)` and the live recompute on a single
/// keystroke is `O(1)` (only the dirty section's height bucket
/// changes).
class PageViewLayout extends StatefulWidget {
  const PageViewLayout({
    super.key,
    required this.onPageCountChanged,
    required this.onCurrentPageChanged,
    this.onOpenSettings,
    this.controller,
    this.bookOverride,
    this.sessionOverride,
  });

  /// Reports total page count to the parent (status-bar wiring).
  final void Function(int total) onPageCountChanged;

  /// Reports the 1-indexed page currently in the viewport (status-bar
  /// "Page X of Y" wiring). Updates on scroll, debounced.
  final void Function(int current) onCurrentPageChanged;

  /// Opens the settings sheet that adjusts page size / margins /
  /// font. Optional — wired by the parent.
  final VoidCallback? onOpenSettings;

  /// Imperative controller — exposes `goToPage` so the editor's ⌘G
  /// shortcut can scroll the live view to an arbitrary page number.
  final PageViewController? controller;

  /// Direct book + session injection for widget tests, bypassing the
  /// `Consumer<EditorProvider>` setup.
  @visibleForTesting
  final WritingModel? bookOverride;
  @visibleForTesting
  final MultiSectionEditingSession? sessionOverride;

  @override
  State<PageViewLayout> createState() => _PageViewLayoutState();
}

/// Imperative handle handed to the parent. Lets ⌘G dialogs scroll the
/// live view to a specific page without reaching into the widget's
/// state directly.
class PageViewController extends ChangeNotifier {
  _PageViewLayoutState? _state;
  int _totalPages = 1;

  void _attach(_PageViewLayoutState state) {
    _state = state;
  }

  void _detach(_PageViewLayoutState state) {
    if (_state == state) _state = null;
  }

  void _setTotalPages(int value) {
    if (_totalPages == value) return;
    _totalPages = value;
    notifyListeners();
  }

  /// Total pages currently rendered. Mirrors the `onPageCountChanged`
  /// callback so dialogs that consume the controller don't need a
  /// second feed.
  int get totalPages => _totalPages;

  /// Test-only: drive the totalPages signal directly so the
  /// `showGoToPageDialog` can validate against a known range.
  /// Production code paths are routed through the private
  /// `_setTotalPages` triggered by the layout's measurement loop.
  @visibleForTesting
  void debugSetTotalPages(int value) => _setTotalPages(value);

  /// Scroll the viewport so that `pageNumber` (1-indexed, clamped to
  /// `[1, totalPages]`) is at the top. Returns `false` if the view is
  /// not currently mounted.
  bool goToPage(int pageNumber) {
    final state = _state;
    if (state == null) return false;
    state._goToPage(pageNumber);
    return true;
  }
}

class _PageViewLayoutState extends State<PageViewLayout> {
  final ScrollController _scroll = ScrollController();
  // Per-section measured rendered height (in scroll-axis pixels).
  // The card wraps the editor in a `_MeasuredBox` that calls back
  // here on every layout pass, so this map updates incrementally as
  // the user types in any one section.
  final Map<String, double> _sectionHeights = {};
  // Section ids in the same order as the rendered list — needed to
  // resolve a scroll offset back to a section + page.
  final List<String> _orderedSectionIds = [];
  static const double _interSectionGap = 24.0;
  static const double _scrollTopPadding = 24.0;
  int _lastReportedTotal = 0;
  int _lastReportedCurrent = 0;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant PageViewLayout old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  // ──── Live page math ────

  int _pagesForHeight(double height, double pageHeightPx) {
    if (pageHeightPx <= 0) return 1;
    return math.max(1, (height / pageHeightPx).ceil());
  }

  int _totalPages(double pageHeightPx) {
    if (_orderedSectionIds.isEmpty) return 1;
    var total = 0;
    for (final id in _orderedSectionIds) {
      final h = _sectionHeights[id] ?? pageHeightPx;
      total += _pagesForHeight(h, pageHeightPx);
    }
    return math.max(1, total);
  }

  /// 1-indexed current page based on viewport center.
  int _currentPage(double pageHeightPx) {
    if (_orderedSectionIds.isEmpty || pageHeightPx <= 0) return 1;
    if (!_scroll.hasClients) return 1;
    final viewportCenter =
        _scroll.offset + _scroll.position.viewportDimension / 2;
    var cumulativePages = 0;
    var sectionTop = _scrollTopPadding;
    for (final id in _orderedSectionIds) {
      final h = _sectionHeights[id] ?? pageHeightPx;
      final sectionPages = _pagesForHeight(h, pageHeightPx);
      final sectionBottom = sectionTop + h;
      if (viewportCenter < sectionBottom) {
        // Inside this section's card.
        final localY = (viewportCenter - sectionTop)
            .clamp(0.0, h - 1);
        final localPage = (localY / pageHeightPx).floor();
        return math.max(1, cumulativePages + localPage + 1);
      }
      cumulativePages += sectionPages;
      sectionTop = sectionBottom + _interSectionGap;
    }
    return math.max(1, cumulativePages);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _emitCurrentPage();
  }

  void _emitCurrentPage([double? pageHeightPx]) {
    final settings = _settingsCache;
    final h = pageHeightPx ?? settings?.pageHeightPx ?? 0;
    if (h <= 0) return;
    final current = _currentPage(h);
    if (current != _lastReportedCurrent) {
      _lastReportedCurrent = current;
      widget.onCurrentPageChanged(current);
    }
  }

  void _emitTotalPages(double pageHeightPx) {
    final total = _totalPages(pageHeightPx);
    if (total != _lastReportedTotal) {
      _lastReportedTotal = total;
      widget.onPageCountChanged(total);
      widget.controller?._setTotalPages(total);
    }
  }

  // ──── Imperative API ────

  void _goToPage(int pageNumber) {
    final settings = _settingsCache;
    if (settings == null) return;
    final pageHeightPx = settings.pageHeightPx;
    if (pageHeightPx <= 0) return;
    final total = _totalPages(pageHeightPx);
    final clamped = pageNumber.clamp(1, total);
    // Find which section and local page the target is in.
    var cumulativePages = 0;
    var sectionTop = _scrollTopPadding;
    for (final id in _orderedSectionIds) {
      final h = _sectionHeights[id] ?? pageHeightPx;
      final sectionPages = _pagesForHeight(h, pageHeightPx);
      if (clamped <= cumulativePages + sectionPages) {
        final localPage = clamped - cumulativePages - 1;
        final targetY = sectionTop + localPage * pageHeightPx;
        if (_scroll.hasClients) {
          final maxOffset = _scroll.position.maxScrollExtent;
          _scroll.animateTo(
            targetY.clamp(0.0, maxOffset),
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          );
        }
        return;
      }
      cumulativePages += sectionPages;
      sectionTop += h + _interSectionGap;
    }
  }

  // Cached for callbacks; refreshed on each build.
  PageLayoutSettings? _settingsCache;

  // ──── Build ────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final overrideBook = widget.bookOverride;
    final overrideSession = widget.sessionOverride;
    if (overrideBook != null && overrideSession != null) {
      final settings =
          overrideBook.pageLayout ?? PageLayoutSettings.standard;
      _settingsCache = settings;
      return _buildLive(overrideBook, overrideSession, settings, isDark);
    }
    return Consumer<EditorProvider>(
      builder: (context, provider, _) {
        final book = provider.activeBook;
        var session = provider.multiSectionSession;
        // Defensive: the session should already be running by the
        // time the page view is on screen (the editor's _setViewMode
        // calls enterMultiSectionMode), but a hot-reload or test
        // mounting the view directly may bypass that. Kick the
        // provider so the view never renders empty.
        if (session == null && book != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            provider.enterMultiSectionMode();
          });
        }
        if (book == null || session == null) {
          return _emptyState(context, 'Loading manuscript…');
        }
        final settings = book.pageLayout ?? PageLayoutSettings.standard;
        _settingsCache = settings;
        return _buildLive(book, session, settings, isDark);
      },
    );
  }

  Widget _emptyState(BuildContext context, String message) {
    final theme = Theme.of(context);
    final color =
        (theme.textTheme.bodyMedium?.color ?? Colors.black).withValues(alpha: 0.55);
    return Container(
      color: theme.brightness == Brightness.dark
          ? const Color(0xFF111111)
          : const Color(0xFFE9E9EE),
      alignment: Alignment.center,
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

  Widget _buildLive(
    WritingModel book,
    MultiSectionEditingSession session,
    PageLayoutSettings settings,
    bool isDark,
  ) {
    final sections = _publishableSections(book);
    // Refresh ordered ids; drop heights for sections that are gone.
    _orderedSectionIds
      ..clear()
      ..addAll(sections.map((s) => s.id));
    _sectionHeights
        .removeWhere((id, _) => !_orderedSectionIds.contains(id));

    if (sections.isEmpty) {
      return _emptyState(context,
          'Add a chapter or scene to see paginated pages.');
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Scale the page card down to fit narrow viewports (mobile).
        final maxPageWidth = settings.pageWidthPx;
        final available = constraints.maxWidth - 48;
        final scale =
            available < maxPageWidth ? available / maxPageWidth : 1.0;
        final renderedWidth = maxPageWidth * scale;
        final pageHeightPx = settings.pageHeightPx * scale;
        // Page total may have changed since we cached heights for
        // sections; emit on the next frame so the parent's status bar
        // updates without us calling setState here mid-build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _emitTotalPages(pageHeightPx);
          _emitCurrentPage(pageHeightPx);
        });
        return Container(
          color: isDark
              ? const Color(0xFF111111)
              : const Color(0xFFE9E9EE),
          child: ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.symmetric(
              vertical: _scrollTopPadding,
              horizontal: 24,
            ),
            itemCount: sections.length,
            cacheExtent: pageHeightPx * 1.5,
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
            itemBuilder: (context, index) {
              final section = sections[index];
              return _LivePageSection(
                key: ValueKey('pageview:${section.id}'),
                section: section,
                session: session,
                settings: settings,
                pageWidth: renderedWidth,
                pageHeightPx: pageHeightPx,
                gap: _interSectionGap,
                scale: scale,
                isDark: isDark,
                pageNumberOffset: _pageNumberOffsetFor(section.id, pageHeightPx),
                onMeasured: (height) {
                  if (!mounted) return;
                  final prev = _sectionHeights[section.id];
                  if (prev != null && (prev - height).abs() < 0.5) return;
                  _sectionHeights[section.id] = height;
                  // Coalesce updates to next frame so multiple
                  // simultaneous remeasures (typing, sync push) emit
                  // a single status-bar refresh.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    _emitTotalPages(pageHeightPx);
                    _emitCurrentPage(pageHeightPx);
                  });
                },
              );
            },
          ),
        );
      },
    );
  }

  /// Sum of pages in every section that comes BEFORE [id]. Used to
  /// label internal page-break dividers with the absolute manuscript
  /// page number rather than the section-local one.
  int _pageNumberOffsetFor(String id, double pageHeightPx) {
    var n = 0;
    for (final sid in _orderedSectionIds) {
      if (sid == id) break;
      final h = _sectionHeights[sid] ?? pageHeightPx;
      n += _pagesForHeight(h, pageHeightPx);
    }
    return n;
  }

  List<SectionModel> _publishableSections(WritingModel book) {
    return book.sections
        .where((s) =>
            s.kind != SectionKind.folder &&
            s.kind != SectionKind.research &&
            s.kind != SectionKind.trash &&
            s.kind != SectionKind.act &&
            s.includeInPublish)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }
}

/// One section, rendered as a page-shaped editable card. The card is
/// at least one page tall (so a short scene still feels like a page);
/// taller content extends the card and renders dashed page-break
/// dividers at every page-height interval.
class _LivePageSection extends StatefulWidget {
  const _LivePageSection({
    required super.key,
    required this.section,
    required this.session,
    required this.settings,
    required this.pageWidth,
    required this.pageHeightPx,
    required this.gap,
    required this.scale,
    required this.isDark,
    required this.pageNumberOffset,
    required this.onMeasured,
  });

  final SectionModel section;
  final MultiSectionEditingSession session;
  final PageLayoutSettings settings;
  final double pageWidth;
  final double pageHeightPx;
  final double gap;
  final double scale;
  final bool isDark;
  final int pageNumberOffset;
  final ValueChanged<double> onMeasured;

  @override
  State<_LivePageSection> createState() => _LivePageSectionState();
}

class _LivePageSectionState extends State<_LivePageSection> {
  QuillController? _controller;
  FocusNode? _focusNode;
  // Track height locally so the header chip can show "1 of N" without
  // needing the parent to re-render.
  double _measuredHeight = 0;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant _LivePageSection old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      _bind();
    }
  }

  @override
  void dispose() {
    final session = widget.session;
    final id = widget.section.id;
    Future.microtask(() {
      if (session.isDisposed) return;
      session.unregister(id);
    });
    super.dispose();
  }

  void _bind() {
    _controller = widget.session.register(widget.section);
    _focusNode = widget.session.focusNode(widget.section);
  }

  int get _internalPageCount =>
      math.max(1, (_measuredHeight / widget.pageHeightPx).ceil());

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final paperColor =
        widget.isDark ? const Color(0xFF1B1B1F) : Colors.white;
    final inkColor = widget.isDark
        ? const Color(0xFFEDEDED)
        : const Color(0xFF111111);
    final mutedColor = inkColor.withValues(alpha: 0.45);
    final dividerColor = inkColor.withValues(alpha: 0.15);

    final controller = _controller!;
    final focusNode = _focusNode!;
    final scale = widget.scale;
    final fontSize = settings.fontSizePx * scale;
    final lineHeight = settings.lineHeight;

    final body = Padding(
      padding: EdgeInsets.fromLTRB(
        settings.marginLeftPx * scale,
        settings.marginTopPx * scale,
        settings.marginRightPx * scale,
        settings.marginBottomPx * scale,
      ),
      child: Semantics(
        label: 'Page editor for section ${_titleOrUntitled(widget.section)}',
        textField: true,
        child: QuillEditor(
          controller: controller,
          focusNode: focusNode,
          scrollController: ScrollController(),
          config: QuillEditorConfig(
            padding: EdgeInsets.zero,
            scrollable: false,
            autoFocus: false,
            expands: false,
            placeholder: 'Start writing…',
            // The default Quill font/size doesn't pick up our page
            // settings — push them through customStyles so the live
            // editor matches the page-shaped chrome.
            customStyles: _buildQuillStyles(
              fontSize: fontSize,
              lineHeight: lineHeight,
              inkColor: inkColor,
              settings: settings,
            ),
          ),
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: widget.gap),
      child: Center(
        child: SizedBox(
          width: widget.pageWidth,
          child: Stack(
            children: [
              // The page card itself. Container's minHeight ensures
              // a short section still occupies one full page.
              Container(
                constraints: BoxConstraints(
                  minHeight: widget.pageHeightPx,
                ),
                decoration: BoxDecoration(
                  color: paperColor,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black
                          .withValues(alpha: widget.isDark ? 0.4 : 0.12),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: _MeasuredBox(
                  onSize: (size) {
                    final h = math.max(size.height, widget.pageHeightPx);
                    if ((_measuredHeight - h).abs() > 0.5) {
                      // Update locally so the header chip reflects
                      // the latest count without waiting on the
                      // parent rebuild.
                      _measuredHeight = h;
                    }
                    widget.onMeasured(h);
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SectionHeader(
                        title: _titleOrUntitled(widget.section),
                        synopsis: widget.section.synopsis,
                        textColor: inkColor,
                        mutedColor: mutedColor,
                        scale: scale,
                      ),
                      SizedBox(height: 8 * scale),
                      body,
                    ],
                  ),
                ),
              ),
              // Internal page-break dividers + page-number badges.
              ..._buildPageBreaks(
                pageHeightPx: widget.pageHeightPx,
                heightSoFar: math.max(_measuredHeight, widget.pageHeightPx),
                dividerColor: dividerColor,
                mutedColor: mutedColor,
              ),
              // Top-right "Page X" badge anchors the page count for
              // accessibility tools (one per section card).
              Positioned(
                top: 6,
                right: 8,
                child: _PageBadge(
                  isDark: widget.isDark,
                  label:
                      '${widget.pageNumberOffset + 1}–${widget.pageNumberOffset + _internalPageCount}',
                  mutedColor: mutedColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _titleOrUntitled(SectionModel s) =>
      s.title.trim().isEmpty ? 'Untitled' : s.title;

  /// Build a horizontal divider + small "Page N" badge for each
  /// internal page break inside this section card. No divider for
  /// the first page (the top of the card itself).
  List<Widget> _buildPageBreaks({
    required double pageHeightPx,
    required double heightSoFar,
    required Color dividerColor,
    required Color mutedColor,
  }) {
    final breaks = <Widget>[];
    if (pageHeightPx <= 0) return breaks;
    final pageCount = math.max(1, (heightSoFar / pageHeightPx).ceil());
    for (var i = 1; i < pageCount; i++) {
      final y = i * pageHeightPx;
      breaks.add(Positioned(
        top: y - 0.5,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(
                child: CustomPaint(
                  painter: _DashedLinePainter(color: dividerColor),
                  size: const Size(double.infinity, 1),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Page ${widget.pageNumberOffset + i + 1}',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: mutedColor,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              Expanded(
                child: CustomPaint(
                  painter: _DashedLinePainter(color: dividerColor),
                  size: const Size(double.infinity, 1),
                ),
              ),
            ],
          ),
        ),
      ));
    }
    return breaks;
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.synopsis,
    required this.textColor,
    required this.mutedColor,
    required this.scale,
  });

  final String title;
  final String synopsis;
  final Color textColor;
  final Color mutedColor;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24 * scale, 24 * scale, 24 * scale, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 14 * scale,
              fontWeight: FontWeight.w700,
              color: mutedColor,
              letterSpacing: 0.3,
            ),
          ),
          if (synopsis.trim().isNotEmpty) ...[
            SizedBox(height: 4 * scale),
            Text(
              synopsis,
              style: GoogleFonts.inter(
                fontSize: 11 * scale,
                fontStyle: FontStyle.italic,
                color: mutedColor,
              ),
            ),
          ],
        ],
      ),
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

/// Painter for the dashed horizontal lines marking internal page
/// breaks. Cheap; no allocations on rebuild.
class _DashedLinePainter extends CustomPainter {
  _DashedLinePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const dashWidth = 4.0;
    const dashSpace = 4.0;
    var x = 0.0;
    final y = size.height / 2;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + dashWidth, size.width), y),
        paint,
      );
      x += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(_DashedLinePainter old) => old.color != color;
}

/// Layout-after-paint reporter. Wraps a child and emits its rendered
/// size to a callback every time the layout changes. Lets the page
/// view track section heights without needing a global key.
class _MeasuredBox extends SingleChildRenderObjectWidget {
  const _MeasuredBox({required this.onSize, required Widget child})
      : super(child: child);
  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasuredBox(onSize: onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasuredBox renderObject) {
    renderObject.onSize = onSize;
  }
}

class _RenderMeasuredBox extends RenderProxyBox {
  _RenderMeasuredBox({required this.onSize});
  ValueChanged<Size> onSize;
  Size _last = Size.zero;

  @override
  void performLayout() {
    super.performLayout();
    if (size != _last) {
      _last = size;
      // Defer the callback so the layout pass completes first — we
      // don't want the listener calling setState mid-layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!attached) return;
        onSize(size);
      });
    }
  }
}

/// Quill style block scaled to the page settings. Flutter Quill's
/// default `DefaultStyles` font sizes don't track our 12 pt / 1.5
/// settings, so we override the body, headings, paragraph spacing,
/// and lists. Everything else falls through to the default theme.
DefaultStyles _buildQuillStyles({
  required double fontSize,
  required double lineHeight,
  required Color inkColor,
  required PageLayoutSettings settings,
}) {
  TextStyle bodyStyle = _fontStyle(
    settings: settings,
    fontSize: fontSize,
    lineHeight: lineHeight,
    color: inkColor,
    weight: FontWeight.w400,
  );
  TextStyle h1Style = _fontStyle(
    settings: settings,
    fontSize: fontSize * 1.7,
    lineHeight: 1.2,
    color: inkColor,
    weight: FontWeight.w700,
  );
  TextStyle h2Style = _fontStyle(
    settings: settings,
    fontSize: fontSize * 1.4,
    lineHeight: 1.25,
    color: inkColor,
    weight: FontWeight.w700,
  );
  TextStyle h3Style = _fontStyle(
    settings: settings,
    fontSize: fontSize * 1.2,
    lineHeight: 1.3,
    color: inkColor,
    weight: FontWeight.w600,
  );

  final base = DefaultStyles();
  return base.merge(DefaultStyles(
    paragraph: DefaultTextBlockStyle(
      bodyStyle,
      const HorizontalSpacing(0, 0),
      VerticalSpacing(0, fontSize * 0.4),
      VerticalSpacing(0, 0),
      null,
    ),
    h1: DefaultTextBlockStyle(
      h1Style,
      const HorizontalSpacing(0, 0),
      VerticalSpacing(fontSize, fontSize * 0.4),
      VerticalSpacing(0, 0),
      null,
    ),
    h2: DefaultTextBlockStyle(
      h2Style,
      const HorizontalSpacing(0, 0),
      VerticalSpacing(fontSize * 0.8, fontSize * 0.3),
      VerticalSpacing(0, 0),
      null,
    ),
    h3: DefaultTextBlockStyle(
      h3Style,
      const HorizontalSpacing(0, 0),
      VerticalSpacing(fontSize * 0.6, fontSize * 0.2),
      VerticalSpacing(0, 0),
      null,
    ),
  ));
}

TextStyle _fontStyle({
  required PageLayoutSettings settings,
  required double fontSize,
  required double lineHeight,
  required Color color,
  required FontWeight weight,
}) {
  switch (settings.font) {
    case PageFont.merriweather:
      return GoogleFonts.merriweather(
          fontSize: fontSize,
          height: lineHeight,
          color: color,
          fontWeight: weight);
    case PageFont.lora:
      return GoogleFonts.lora(
          fontSize: fontSize,
          height: lineHeight,
          color: color,
          fontWeight: weight);
    case PageFont.sourceSerif:
      return GoogleFonts.sourceSerif4(
          fontSize: fontSize,
          height: lineHeight,
          color: color,
          fontWeight: weight);
    case PageFont.inter:
      return GoogleFonts.inter(
          fontSize: fontSize,
          height: lineHeight,
          color: color,
          fontWeight: weight);
    case PageFont.jetbrainsMono:
      return GoogleFonts.jetBrainsMono(
          fontSize: fontSize,
          height: lineHeight,
          color: color,
          fontWeight: weight);
  }
}

/// "Go to page N" dialog wired into ⌘G.
Future<void> showGoToPageDialog({
  required BuildContext context,
  required PageViewController controller,
}) async {
  final theme = Theme.of(context);
  final textColor = theme.textTheme.bodyMedium?.color ?? Colors.black;
  final fieldCtrl = TextEditingController();
  final formKey = GlobalKey<FormState>();
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        'Go to page',
        style: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: textColor,
        ),
      ),
      content: Form(
        key: formKey,
        child: ValueListenableBuilder<int>(
          valueListenable: _PageViewControllerListener(controller),
          builder: (_, total, _) => TextFormField(
            controller: fieldCtrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: '1 – $total',
              border: const OutlineInputBorder(),
            ),
            validator: (v) {
              final n = int.tryParse((v ?? '').trim());
              if (n == null) return 'Enter a page number';
              if (n < 1 || n > total) return 'Out of range (1–$total)';
              return null;
            },
            onFieldSubmitted: (_) {
              if (formKey.currentState?.validate() ?? false) {
                final n = int.parse(fieldCtrl.text.trim());
                Navigator.of(ctx).pop();
                controller.goToPage(n);
              }
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (formKey.currentState?.validate() ?? false) {
              final n = int.parse(fieldCtrl.text.trim());
              Navigator.of(ctx).pop();
              controller.goToPage(n);
            }
          },
          child: const Text('Go'),
        ),
      ],
    ),
  );
}

/// Adapter so `ValueListenableBuilder` can react to total-page
/// changes on a [PageViewController]. The dialog needs to refresh
/// its hint text and validator when the user types in the
/// background.
class _PageViewControllerListener extends ValueNotifier<int> {
  _PageViewControllerListener(this._source) : super(_source.totalPages) {
    _source.addListener(_onChange);
  }
  final PageViewController _source;

  void _onChange() {
    value = _source.totalPages;
  }

  @override
  void dispose() {
    _source.removeListener(_onChange);
    super.dispose();
  }
}
