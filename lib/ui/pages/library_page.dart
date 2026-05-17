import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/library_book_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';
import 'package:inkspacex/ui/widgets/book_label_chip.dart';

/// "My Library" — the user's bookcase, bucketed by reading state.
///
/// One tab per `BookLabel` (plus an "All" tab). Each tab renders a
/// grid of cards; the chip in the top-right corner names the state.
/// Tapping a card opens the post detail page at the user's last
/// position (resume), or at the top for `saved` items.
///
/// Counts on the tab strip are refreshed lazily — first paint kicks
/// off both `getLibraryCounts()` and `getLibrary(label: current tab)`
/// in parallel so the page hydrates in one round trip from the user's
/// perspective.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  // Tab order — `null` is the "All" tab, others map to the matching
  // BookLabel. Order is intentional: All first (lowest cognitive load),
  // then the verbs (Reading → Finished → Saved → Set aside) sorted by
  // how often a user is likely to flip to that tab.
  static const List<BookLabel?> _tabs = [
    null,
    BookLabel.reading,
    BookLabel.finished,
    BookLabel.saved,
    BookLabel.abandoned,
  ];

  late final TabController _tabsCtrl;
  LibraryCountsModel _counts = const LibraryCountsModel();

  /// Cached per-tab lists. Loaded on first tab focus; re-fetched on
  /// pull-to-refresh. Keeping per-tab caches means flipping between
  /// tabs is instant after the first visit.
  final Map<BookLabel?, _TabState> _byTab = {
    for (final t in _tabs) t: _TabState(),
  };

  ApiDataService get _api => context.read<AuthProvider>().dataService;

  @override
  void initState() {
    super.initState();
    _tabsCtrl = TabController(length: _tabs.length, vsync: this);
    _tabsCtrl.addListener(() {
      if (!_tabsCtrl.indexIsChanging) {
        _ensureLoaded(_tabs[_tabsCtrl.index]);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureLoaded(null);
      _refreshCounts();
    });
  }

  @override
  void dispose() {
    _tabsCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshCounts() async {
    try {
      final c = await _api.getLibraryCounts();
      if (!mounted) return;
      setState(() => _counts = c);
    } catch (_) {
      // Counts are nice-to-have for the tab badges; failure is silent.
    }
  }

  Future<void> _ensureLoaded(BookLabel? label) async {
    final t = _byTab[label]!;
    if (t.loaded || t.loading) return;
    setState(() => t.loading = true);
    try {
      final items = await _api.getLibrary(label: label);
      if (!mounted) return;
      setState(() {
        t.items = items;
        t.loaded = true;
        t.error = null;
        t.loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        t.error = e.toString();
        t.loading = false;
      });
    }
  }

  Future<void> _reload(BookLabel? label) async {
    final t = _byTab[label]!;
    t.loaded = false;
    await _ensureLoaded(label);
    await _refreshCounts();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : Colors.black;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        leading: IconButton(
          icon: const Icon(CupertinoIcons.back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          'My Library',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: textColor,
            letterSpacing: -0.2,
          ),
        ),
        bottom: TabBar(
          controller: _tabsCtrl,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          labelColor: textColor,
          unselectedLabelColor: textColor.withValues(alpha: 0.55),
          indicatorColor: textColor,
          indicatorWeight: 2,
          dividerColor: Colors.transparent,
          labelStyle: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          tabs: [for (final label in _tabs) _buildTabLabel(label)],
        ),
      ),
      body: TabBarView(
        controller: _tabsCtrl,
        children: [for (final label in _tabs) _buildTabBody(label)],
      ),
    );
  }

  Widget _buildTabLabel(BookLabel? label) {
    final name = label == null
        ? 'All'
        : (BookLabelStyle.shortLabel[label] ?? '');
    final n = _counts.forLabel(label);
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name),
          if (n > 0) ...[
            const SizedBox(width: 6),
            Text(
              '$n',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: (label == null
                        ? Colors.grey
                        : BookLabelStyle.color[label])!
                    .withValues(alpha: 0.85),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTabBody(BookLabel? label) {
    final t = _byTab[label]!;
    if (t.loading && t.items.isEmpty) {
      return const Center(child: AppSpinner());
    }
    if (t.error != null && t.items.isEmpty) {
      return _ErrorView(error: t.error!, onRetry: () => _reload(label));
    }
    if (t.items.isEmpty) {
      return _EmptyView(label: label);
    }
    return RefreshIndicator(
      onRefresh: () => _reload(label),
      child: GridView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 14,
          mainAxisSpacing: 18,
          childAspectRatio: 0.58,
        ),
        itemCount: t.items.length,
        itemBuilder: (context, i) => _BookCard(book: t.items[i]),
      ),
    );
  }
}

class _TabState {
  List<LibraryBookModel> items = const [];
  bool loaded = false;
  bool loading = false;
  String? error;
}

class _BookCard extends StatelessWidget {
  final LibraryBookModel book;

  const _BookCard({required this.book});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final subtle = textColor.withValues(alpha: 0.62);

    return GestureDetector(
      onTap: () => context.push('/post/${book.feedItemId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 3 / 4,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: book.imageUrl != null && book.imageUrl!.isNotEmpty
                        ? AppNetworkImage(
                            url: book.imageUrl,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            color: isDark
                                ? const Color(0xFF1A1A1A)
                                : const Color(0xFFEFEFEF),
                            child: Center(
                              child: Icon(
                                CupertinoIcons.book,
                                size: 28,
                                color: subtle,
                              ),
                            ),
                          ),
                  ),
                ),
                // Progress hairline along the bottom of the cover — only
                // for in-progress / abandoned cards. Skipped for finished
                // (full) and saved (none).
                if (book.label == BookLabel.reading ||
                    book.label == BookLabel.abandoned)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(10),
                        bottomRight: Radius.circular(10),
                      ),
                      child: LinearProgressIndicator(
                        value: ((book.scrollPosition ?? 0).clamp(0, 1)),
                        minHeight: 3,
                        backgroundColor: Colors.black.withValues(alpha: 0.18),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          BookLabelStyle.color[book.label] ?? Colors.amber,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: BookLabelChip(label: book.label),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            book.title ?? 'Untitled',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: textColor,
              height: 1.25,
            ),
          ),
          if (book.author != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                book.author!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  color: subtle,
                  height: 1.2,
                ),
              ),
            ),
          // Per-row footer — finished date or "last opened X ago".
          if (book.label == BookLabel.finished && book.finishedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Finished ${_formatDate(book.finishedAt!)}',
                style: GoogleFonts.inter(
                  fontSize: 10.5,
                  color: subtle,
                ),
              ),
            )
          else if (book.label == BookLabel.reading && book.lastReadAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _relativeTime(book.lastReadAt!),
                style: GoogleFonts.inter(
                  fontSize: 10.5,
                  color: subtle,
                ),
              ),
            )
          else if (book.label == BookLabel.saved && book.shelfName != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'On "${book.shelfName!}"',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 10.5,
                  color: subtle,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final now = DateTime.now();
    if (dt.year == now.year) return '${months[dt.month - 1]} ${dt.day}';
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
    return _formatDate(dt);
  }
}

class _EmptyView extends StatelessWidget {
  final BookLabel? label;
  const _EmptyView({required this.label});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subtle = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.6);
    final (icon, line1, line2) = switch (label) {
      BookLabel.reading => (
        CupertinoIcons.book,
        'Nothing on the go',
        'Books you start show up here so you can pick up where you left off.',
      ),
      BookLabel.finished => (
        CupertinoIcons.checkmark_seal,
        'No finished books yet',
        'Once you reach the end of a book it lands here as a record.',
      ),
      BookLabel.saved => (
        CupertinoIcons.bookmark,
        'Your saved shelf is empty',
        'Save books from the feed to read later — they\'ll wait here.',
      ),
      BookLabel.abandoned => (
        CupertinoIcons.clock,
        'Nothing set aside',
        'Books you started but haven\'t touched in a month appear here.',
      ),
      null => (
        CupertinoIcons.book,
        'Your Library is empty',
        'Read, save, or finish a book and it shows up here.',
      ),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: subtle),
            const SizedBox(height: 14),
            Text(
              line1,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: subtle,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              line2,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: subtle.withValues(alpha: 0.75),
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(CupertinoIcons.exclamationmark_triangle,
                size: 36, color: Colors.orange),
            const SizedBox(height: 14),
            Text(
              "Couldn't load your library",
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
              color: Colors.blue,
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
