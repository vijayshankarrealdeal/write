import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/storage_service.dart';
import 'package:inkspacex/ui/utilities/responsive_layout.dart';

const double _kMaxContentWidth = 1080;

enum _SearchScope { all, stories, authors }

class _DismissIntent extends Intent {
  const _DismissIntent();
}

extension _SearchScopeLabel on _SearchScope {
  String get label => switch (this) {
        _SearchScope.all => 'All',
        _SearchScope.stories => 'Stories',
        _SearchScope.authors => 'Authors',
      };
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;
  String _query = '';
  _SearchScope _scope = _SearchScope.all;

  bool _loadingPopular = true;
  bool _searching = false;
  List<FeedItemModel> _popular = const [];
  List<FeedItemModel> _rawResults = const [];
  List<FeedItemModel> _results = const [];
  List<String> _recent = const [];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _loadInitial();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _loadInitial() {
    final storage = context.read<StorageService>();
    setState(() => _recent = storage.getRecentSearches());
    context.read<AuthProvider>().dataService.getPopularFeedItems(limit: 12).then((items) {
      if (!mounted) return;
      setState(() {
        _popular = items;
        _loadingPopular = false;
      });
    }).catchError((_) {
      if (!mounted) return;
      setState(() => _loadingPopular = false);
    });
  }

  void _onQueryChanged() {
    final q = _controller.text.trim();
    _debounce?.cancel();
    if (q.isEmpty) {
      setState(() {
        _query = '';
        _rawResults = const [];
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() {
      _query = q;
      _searching = true;
    });
    _debounce = Timer(const Duration(milliseconds: 280), () => _runSearch(q));
  }

  Future<void> _runSearch(String q) async {
    try {
      final results = await context.read<AuthProvider>().dataService.searchFeedItems(q);
      if (!mounted || _controller.text.trim() != q) return;
      setState(() {
        _rawResults = results;
        _results = _applyScope(results);
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _searching = false);
    }
  }

  List<FeedItemModel> _applyScope(List<FeedItemModel> items) {
    switch (_scope) {
      case _SearchScope.all:
        return items;
      case _SearchScope.stories:
        return items;
      case _SearchScope.authors:
        final seen = <String>{};
        return items.where((i) {
          final key = i.author.toLowerCase();
          if (key.isEmpty || seen.contains(key)) return false;
          seen.add(key);
          return true;
        }).toList();
    }
  }

  void _setScope(_SearchScope s) {
    setState(() {
      _scope = s;
      _results = _applyScope(_rawResults);
    });
  }

  Future<void> _commitSearch(String q) async {
    final term = q.trim();
    if (term.isEmpty) return;
    final storage = context.read<StorageService>();
    await storage.addRecentSearch(term);
    if (!mounted) return;
    setState(() => _recent = storage.getRecentSearches());
  }

  Future<void> _removeRecent(String q) async {
    final storage = context.read<StorageService>();
    await storage.removeRecentSearch(q);
    if (!mounted) return;
    setState(() => _recent = storage.getRecentSearches());
  }

  Future<void> _clearRecent() async {
    final storage = context.read<StorageService>();
    await storage.clearRecentSearches();
    if (!mounted) return;
    setState(() => _recent = const []);
  }

  void _applyChip(String q) {
    _controller.text = q;
    _controller.selection = TextSelection.collapsed(offset: q.length);
    _focusNode.requestFocus();
  }

  void _openPost(FeedItemModel item) {
    _commitSearch(_query.isEmpty ? item.title : _query);
    context.push('/post/${item.id}', extra: item);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFF8F9FA);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = Breakpoints.isMobile(width);
    final hPad = isMobile ? 16.0 : 40.0;

    return Scaffold(
      backgroundColor: bgColor,
      body: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.escape): _DismissIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _DismissIntent: CallbackAction<_DismissIntent>(
              onInvoke: (_) {
                if (_controller.text.isNotEmpty) {
                  _controller.clear();
                  _focusNode.requestFocus();
                } else if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/');
                }
                return null;
              },
            ),
          },
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _kMaxContentWidth),
                child: Column(
                  children: [
                    _buildHeader(isDark, textColor, hPad, isMobile),
                    if (_query.isNotEmpty)
                      _buildScopeSegments(isDark, textColor, hPad),
                    Expanded(
                      child: _query.isEmpty
                          ? _buildDiscovery(isDark, textColor, hPad, width)
                          : _buildResults(isDark, textColor, hPad, width),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header (search field + cancel)
  // ---------------------------------------------------------------------------

  Widget _buildHeader(
    bool isDark,
    Color textColor,
    double hPad,
    bool isMobile,
  ) {
    final muted = isDark ? Colors.white54 : Colors.black45;
    final fieldBg = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.white;
    final fontSize = isMobile ? 15.0 : 16.0;
    final vInner = isMobile ? 12.0 : 16.0;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        hPad,
        isMobile ? 10 : 20,
        hPad,
        isMobile ? 10 : 16,
      ),
      child: Row(
        children: [
          Expanded(
            child: CupertinoTextField(
              controller: _controller,
              focusNode: _focusNode,
              placeholder: 'Search stories, authors, or tags',
              placeholderStyle: GoogleFonts.inter(
                color: muted,
                fontSize: fontSize,
              ),
              style: GoogleFonts.inter(
                color: textColor,
                fontSize: fontSize,
              ),
              cursorColor: textColor,
              textInputAction: TextInputAction.search,
              onSubmitted: (v) => _commitSearch(v),
              prefix: Padding(
                padding: EdgeInsets.only(left: isMobile ? 12 : 16),
                child: Icon(
                  CupertinoIcons.search,
                  size: isMobile ? 18 : 20,
                  color: muted,
                ),
              ),
              suffix: _controller.text.isNotEmpty
                  ? GestureDetector(
                      onTap: () {
                        _controller.clear();
                        _focusNode.requestFocus();
                      },
                      child: Padding(
                        padding: EdgeInsets.only(right: isMobile ? 10 : 14),
                        child: Icon(
                          CupertinoIcons.clear_circled_solid,
                          size: isMobile ? 18 : 20,
                          color: muted,
                        ),
                      ),
                    )
                  : (!isMobile
                      ? Padding(
                          padding: const EdgeInsets.only(right: 14),
                          child: _KeyboardHint(isDark: isDark),
                        )
                      : null),
              padding: EdgeInsets.symmetric(
                horizontal: isMobile ? 10 : 14,
                vertical: vInner,
              ),
              decoration: BoxDecoration(
                color: fieldBg,
                borderRadius: BorderRadius.circular(isMobile ? 12 : 14),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.08),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            onPressed: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/');
              }
            },
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(
                fontSize: fontSize,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Scope segmented control
  // ---------------------------------------------------------------------------

  Widget _buildScopeSegments(bool isDark, Color textColor, double hPad) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: hPad),
        itemCount: _SearchScope.values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final scope = _SearchScope.values[i];
          final selected = scope == _scope;
          final bg = selected
              ? (isDark ? Colors.white : Colors.black)
              : (isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.black.withValues(alpha: 0.04));
          final fg = selected
              ? (isDark ? Colors.black : Colors.white)
              : textColor.withValues(alpha: 0.75);
          return GestureDetector(
            onTap: () => _setScope(scope),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                scope.label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Discovery (empty query) – recent + popular
  // ---------------------------------------------------------------------------

  Widget _buildDiscovery(
    bool isDark,
    Color textColor,
    double hPad,
    double width,
  ) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        if (_recent.isNotEmpty) _buildRecentSection(isDark, textColor, hPad),
        _buildPopularSection(isDark, textColor, hPad, width),
      ],
    );
  }

  Widget _buildRecentSection(bool isDark, Color textColor, double hPad) {
    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, 8, hPad, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Recent searches',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _clearRecent,
                child: Text(
                  'Clear',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: textColor.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _recent.map((q) => _buildRecentChip(q, isDark, textColor)).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentChip(String q, bool isDark, Color textColor) {
    return GestureDetector(
      onTap: () => _applyChip(q),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.06),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.clock,
              size: 13,
              color: textColor.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 6),
            Text(
              q,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: textColor,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _removeRecent(q),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  CupertinoIcons.xmark,
                  size: 11,
                  color: textColor.withValues(alpha: 0.45),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPopularSection(
    bool isDark,
    Color textColor,
    double hPad,
    double width,
  ) {
    final isMobile = Breakpoints.isMobile(width);
    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, 8, hPad, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                CupertinoIcons.flame_fill,
                size: 16,
                color: Color(0xFFFF6B35),
              ),
              const SizedBox(width: 8),
              Text(
                'Popular',
                style: GoogleFonts.inter(
                  fontSize: isMobile ? 15 : 17,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _popular.isEmpty ? '' : '${_popular.length}',
                style: GoogleFonts.inter(
                  fontSize: isMobile ? 13 : 14,
                  fontWeight: FontWeight.w500,
                  color: textColor.withValues(alpha: 0.35),
                ),
              ),
            ],
          ),
          SizedBox(height: isMobile ? 14 : 18),
          if (_loadingPopular)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CupertinoActivityIndicator()),
            )
          else if (_popular.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  'No stories yet — be the first to publish.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: textColor.withValues(alpha: 0.5),
                  ),
                ),
              ),
            )
          else
            _buildPopularGrid(isDark, textColor),
        ],
      ),
    );
  }

  Widget _buildPopularGrid(bool isDark, Color textColor) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final cols = w >= 960
            ? 6
            : w >= 720
                ? 5
                : w >= 520
                    ? 4
                    : w >= 360
                        ? 3
                        : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _popular.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: 16,
            mainAxisSpacing: 22,
            childAspectRatio: 0.58,
          ),
          itemBuilder: (context, i) =>
              _buildPopularCard(_popular[i], isDark, textColor),
        );
      },
    );
  }

  Widget _buildPopularCard(
    FeedItemModel item,
    bool isDark,
    Color textColor,
  ) {
    return _HoverLift(
      child: GestureDetector(
        onTap: () => _openPost(item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 3 / 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.12),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _coverImage(item, isDark),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: textColor,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              item.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 11,
                color: textColor.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Results
  // ---------------------------------------------------------------------------

  Widget _buildResults(
    bool isDark,
    Color textColor,
    double hPad,
    double width,
  ) {
    if (_searching && _results.isEmpty) {
      return const Center(child: CupertinoActivityIndicator());
    }
    if (_results.isEmpty) {
      return _buildNoResults(textColor);
    }

    final isMobile = Breakpoints.isMobile(width);

    if (_scope == _SearchScope.authors) {
      final cols = isMobile ? 1 : 2;
      return GridView.builder(
        padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 32),
        itemCount: _results.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: isMobile ? 0 : 10,
          crossAxisSpacing: 20,
          mainAxisExtent: 72,
        ),
        itemBuilder: (context, i) =>
            _buildAuthorRow(_results[i], isDark, textColor),
      );
    }

    if (isMobile) {
      return ListView.separated(
        padding: EdgeInsets.fromLTRB(hPad, 8, hPad, 32),
        itemCount: _results.length,
        separatorBuilder: (_, __) => const SizedBox(height: 14),
        itemBuilder: (context, i) =>
            _buildStoryRow(_results[i], isDark, textColor),
      );
    }

    return GridView.builder(
      padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 32),
      itemCount: _results.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 20,
        mainAxisSpacing: 14,
        mainAxisExtent: 118,
      ),
      itemBuilder: (context, i) =>
          _buildStoryCard(_results[i], isDark, textColor),
    );
  }

  /// Desktop result card (used in the 2-column grid). Wraps the story row with
  /// a hoverable card chrome.
  Widget _buildStoryCard(FeedItemModel item, bool isDark, Color textColor) {
    return _HoverLift(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF121212) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.06),
          ),
        ),
        child: _buildStoryRow(item, isDark, textColor),
      ),
    );
  }

  Widget _buildStoryRow(FeedItemModel item, bool isDark, Color textColor) {
    final subtle = textColor.withValues(alpha: 0.55);
    return GestureDetector(
      onTap: () => _openPost(item),
      behavior: HitTestBehavior.opaque,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 78,
              child: _coverImage(item, isDark),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _highlightedTitle(item.title),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  item.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(fontSize: 12, color: subtle),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(CupertinoIcons.heart, size: 11, color: subtle),
                    const SizedBox(width: 3),
                    Text(
                      '${item.likesCount}',
                      style: GoogleFonts.inter(fontSize: 11, color: subtle),
                    ),
                    const SizedBox(width: 10),
                    Icon(CupertinoIcons.chat_bubble, size: 11, color: subtle),
                    const SizedBox(width: 3),
                    Text(
                      '${item.commentsCount}',
                      style: GoogleFonts.inter(fontSize: 11, color: subtle),
                    ),
                    if (item.genres.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          '· ${item.genres.first}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(fontSize: 11, color: subtle),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Icon(
            CupertinoIcons.chevron_right,
            size: 14,
            color: subtle,
          ),
        ],
      ),
    );
  }

  Widget _buildAuthorRow(FeedItemModel item, bool isDark, Color textColor) {
    final subtle = textColor.withValues(alpha: 0.55);
    return GestureDetector(
      onTap: () => _openPost(item),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: isDark ? Colors.white12 : Colors.black12,
              child: Text(
                _initials(item.author),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.author,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Author',
                    style: GoogleFonts.inter(fontSize: 12, color: subtle),
                  ),
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, size: 14, color: subtle),
          ],
        ),
      ),
    );
  }

  Widget _buildNoResults(Color textColor) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.search,
              size: 36,
              color: textColor.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 14),
            Text(
              'No results for "$_query"',
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Try different keywords or check spelling.',
              style: GoogleFonts.inter(
                fontSize: 13,
                color: textColor.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Widget _coverImage(FeedItemModel item, bool isDark) {
    final placeholder = Container(
      color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFEDEFF2),
      alignment: Alignment.center,
      child: Icon(
        CupertinoIcons.book,
        color: isDark ? Colors.white24 : Colors.black26,
      ),
    );
    if (item.imageUrl.isEmpty) return placeholder;
    return CachedNetworkImage(
      imageUrl: item.imageUrl,
      fit: BoxFit.cover,
      placeholder: (_, __) => placeholder,
      errorWidget: (_, __, ___) => placeholder,
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    final first = parts.first.substring(0, 1).toUpperCase();
    final last = parts.length > 1
        ? parts.last.substring(0, 1).toUpperCase()
        : '';
    return '$first$last';
  }

  /// Returns the title as-is; kept as a seam for future inline highlight styling.
  String _highlightedTitle(String title) => title;
}

/// Subtle lift-on-hover affordance for desktop/web pointer input.
/// No-op on touch — the AnimatedScale only triggers via MouseRegion events.
class _HoverLift extends StatefulWidget {
  final Widget child;
  const _HoverLift({required this.child});

  @override
  State<_HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<_HoverLift> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        scale: _hovering ? 1.02 : 1.0,
        child: widget.child,
      ),
    );
  }
}

/// Small ⌘K / Esc keyboard hint shown inside the desktop search field.
class _KeyboardHint extends StatelessWidget {
  final bool isDark;
  const _KeyboardHint({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final bg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.05);
    final fg = isDark ? Colors.white70 : Colors.black54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'esc',
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: fg,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
