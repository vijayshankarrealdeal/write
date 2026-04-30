import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/services/storage_service.dart';
import 'package:inkspacex/ui/utilities/responsive_layout.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';

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
  bool _allTagsExpanded = false;
  bool _searchFocused = false;
  List<FeedItemModel> _popular = const [];
  List<FeedItemModel> _results = const [];
  List<PublicUser> _users = const [];
  List<String> _recent = const [];
  FeedFacets _facets = const FeedFacets(genres: [], tags: [], writingTypes: []);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
    _focusNode.addListener(_onFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _loadInitial();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focusNode.removeListener(_onFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    if (_searchFocused != _focusNode.hasFocus) {
      setState(() => _searchFocused = _focusNode.hasFocus);
    }
  }

  void _loadInitial() {
    final storage = context.read<StorageService>();
    setState(() => _recent = storage.getRecentSearches());
    final api = context.read<AuthProvider>().dataService;
    api.getPopularFeedItems(limit: 12).then((items) {
      if (!mounted) return;
      setState(() {
        _popular = items;
        _loadingPopular = false;
      });
    }).catchError((_) {
      if (!mounted) return;
      setState(() => _loadingPopular = false);
    });
    api.getFeedFacets().then((facets) {
      if (!mounted) return;
      setState(() => _facets = facets);
    });
  }

  void _onQueryChanged() {
    final q = _controller.text.trim();
    _debounce?.cancel();
    if (q.isEmpty) {
      setState(() {
        _query = '';
        _results = const [];
        _users = const [];
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
    AnalyticsService.instance.track(
      'search_submitted',
      screen: '/search',
      action: 'submit',
      // Capture only the query length and scope — the raw query can leak
      // PII (an author's full name, an email, a private title in
      // progress) and we don't need it for funnel/health questions.
      properties: {
        'query_length': q.length,
        'scope': _scope.name,
      },
    );
    final api = context.read<AuthProvider>().dataService;
    try {
      // Fire stories + authors in parallel — they're independent and the
      // result panes render side-by-side, so waiting sequentially would
      // double the perceived latency for no reason.
      final results = await Future.wait([
        api.searchFeedItems(q),
        api.searchUsers(q),
      ]);
      if (!mounted || _controller.text.trim() != q) return;
      final stories = results[0] as List<FeedItemModel>;
      final users = results[1] as List<PublicUser>;
      setState(() {
        _users = users;
        _results = stories;
        _searching = false;
      });
      AnalyticsService.instance.track(
        'search_results_loaded',
        screen: '/search',
        action: 'success',
        properties: {
          'story_count': stories.length,
          'user_count': users.length,
          'query_length': q.length,
        },
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _searching = false);
    }
  }

  void _setScope(_SearchScope s) {
    setState(() {
      _scope = s;
    });
  }

  bool get _showStories =>
      _scope == _SearchScope.all || _scope == _SearchScope.stories;
  bool get _showAuthors =>
      _scope == _SearchScope.all || _scope == _SearchScope.authors;

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
        ? Colors.white.withValues(alpha: _searchFocused ? 0.08 : 0.06)
        : Colors.white;
    final fontSize = isMobile ? 15.0 : 17.0;
    final vInner = isMobile ? 12.0 : 18.0;
    const accent = Color(0xFF2563EB);

    final field = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(isMobile ? 12 : 16),
        boxShadow: _searchFocused
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: 0.18),
                  blurRadius: 28,
                  spreadRadius: 1,
                ),
              ]
            : const [],
      ),
      child: CupertinoTextField(
        controller: _controller,
        focusNode: _focusNode,
        placeholder: 'Search stories, authors, or tags',
        placeholderStyle: GoogleFonts.inter(
          color: muted,
          fontSize: fontSize,
          letterSpacing: -0.1,
        ),
        style: GoogleFonts.inter(
          color: textColor,
          fontSize: fontSize,
          letterSpacing: -0.1,
        ),
        cursorColor: accent,
        textInputAction: TextInputAction.search,
        onSubmitted: (v) => _commitSearch(v),
        prefix: Padding(
          padding: EdgeInsets.only(left: isMobile ? 12 : 18),
          child: Icon(
            CupertinoIcons.search,
            size: isMobile ? 18 : 20,
            color: _searchFocused ? accent : muted,
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
          borderRadius: BorderRadius.circular(isMobile ? 12 : 16),
          border: Border.all(
            color: _searchFocused
                ? accent.withValues(alpha: 0.55)
                : (isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.08)),
            width: _searchFocused ? 1.4 : 1.0,
          ),
        ),
      ),
    );

    if (isMobile) {
      // Mobile keeps the explicit Cancel since esc isn't reachable on touch.
      return Padding(
        padding: EdgeInsets.fromLTRB(hPad, 10, hPad, 10),
        child: Row(
          children: [
            Expanded(child: field),
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

    // Desktop: centered, max 720, generous breathing room — esc hint is
    // already inside the field so the trailing Cancel link disappears.
    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, 28, hPad, 8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: field,
        ),
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
    final isMobile = Breakpoints.isMobile(width);
    final authors = _authorsFromPopular();
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 60),
      children: [
        if (_recent.isNotEmpty) _buildRecentSection(isDark, textColor, hPad),

        // Lead with covers — books are the product, taxonomy is a service.
        _buildPopularSection(isDark, textColor, hPad, width),

        if (authors.isNotEmpty)
          _buildAuthorsStrip(authors, isDark, textColor, hPad, isMobile),

        if (_facets.genres.isNotEmpty)
          _buildGenreCards(
            entries: _facets.genres,
            isDark: isDark,
            textColor: textColor,
            hPad: hPad,
            isMobile: isMobile,
          ),

        if (_facets.tags.isNotEmpty)
          _buildTagCloudSection(
            entries: _facets.tags,
            isDark: isDark,
            textColor: textColor,
            hPad: hPad,
          ),

        if (_facets.writingTypes.isNotEmpty)
          _buildFacetSection(
            title: 'Forms',
            entries: _facets.writingTypes,
            isDark: isDark,
            textColor: textColor,
            hPad: hPad,
            kind: 'type',
          ),
      ],
    );
  }

  /// De-duplicates `_popular` by authorId and returns up to 8 unique authors
  /// for the discovery "Authors to follow" strip. We don't have a dedicated
  /// "popular authors" endpoint yet, so a soft surface from the popular feed
  /// is good enough — the same authors that wrote the popular stories *are*
  /// the popular authors.
  List<({String id, String name})> _authorsFromPopular() {
    final seen = <String>{};
    final out = <({String id, String name})>[];
    for (final p in _popular) {
      if (p.authorId.isEmpty || p.author.isEmpty) continue;
      if (seen.contains(p.authorId)) continue;
      seen.add(p.authorId);
      out.add((id: p.authorId, name: p.author));
      if (out.length >= 8) break;
    }
    return out;
  }

  // Browse-by-facet rows. Tapping a chip opens TagFeedPage for the picked
  // value. Replaces the standalone Explore page so search and browse live
  // on the same surface.
  Widget _buildFacetSection({
    required String title,
    required List<FacetEntry> entries,
    required bool isDark,
    required Color textColor,
    required double hPad,
    required String kind,
    String prefix = '',
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, 8, hPad, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: entries
                .map(
                  (e) => _buildFacetChip(
                    label: '$prefix${e.value}',
                    count: e.count,
                    isDark: isDark,
                    textColor: textColor,
                    onTap: () => context.push(
                      '/tag-feed/$kind/${Uri.encodeComponent(e.value)}',
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildFacetChip({
    required String label,
    required int count,
    required bool isDark,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    final subtle = textColor.withValues(alpha: 0.55);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.07)
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
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: subtle,
              ),
            ),
          ],
        ),
      ),
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
      padding: EdgeInsets.fromLTRB(hPad, isMobile ? 12 : 28, hPad, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DiscoveryHeader(
            icon: CupertinoIcons.flame_fill,
            iconColor: const Color(0xFFFF6B35),
            title: 'Popular',
            subtitle: 'Reader-favourite stories right now',
            isMobile: isMobile,
            textColor: textColor,
          ),
          SizedBox(height: isMobile ? 14 : 22),
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
        // Larger, more cinematic cards on desktop — fewer columns so each
        // cover earns its space.
        final cols = w >= 1200
            ? 5
            : w >= 900
                ? 4
                : w >= 600
                    ? 3
                    : w >= 380
                        ? 3
                        : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _popular.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: w >= 600 ? 22 : 14,
            mainAxisSpacing: w >= 600 ? 30 : 22,
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
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black
                          .withValues(alpha: isDark ? 0.55 : 0.18),
                      blurRadius: 28,
                      offset: const Offset(0, 14),
                      spreadRadius: -4,
                    ),
                    BoxShadow(
                      color: Colors.black
                          .withValues(alpha: isDark ? 0.35 : 0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: _coverImage(item, isDark),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.playfairDisplay(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: textColor,
                height: 1.25,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              item.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: textColor.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Authors strip — derived from popular feed for now (no dedicated endpoint).
  // ---------------------------------------------------------------------------
  Widget _buildAuthorsStrip(
    List<({String id, String name})> authors,
    bool isDark,
    Color textColor,
    double hPad,
    bool isMobile,
  ) {
    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, isMobile ? 18 : 28, hPad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DiscoveryHeader(
            icon: CupertinoIcons.person_2_fill,
            iconColor: const Color(0xFF8B5CF6),
            title: 'Authors to follow',
            subtitle: 'Voices behind the popular stories',
            isMobile: isMobile,
            textColor: textColor,
          ),
          SizedBox(height: isMobile ? 14 : 18),
          SizedBox(
            height: 116,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: authors.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (_, i) {
                final a = authors[i];
                return _AuthorChip(
                  authorId: a.id,
                  name: a.name,
                  isDark: isDark,
                  textColor: textColor,
                  onTap: () => context.push('/u/${a.id}'),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Genre cards — visual tiles with palette-derived gradients, replacing the
  // bare-pill list. Each tile is tappable and routes into the same tag-feed.
  // ---------------------------------------------------------------------------
  Widget _buildGenreCards({
    required List<FacetEntry> entries,
    required bool isDark,
    required Color textColor,
    required double hPad,
    required bool isMobile,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, isMobile ? 22 : 32, hPad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DiscoveryHeader(
            icon: CupertinoIcons.square_grid_2x2_fill,
            iconColor: const Color(0xFF10B981),
            title: 'Browse genres',
            subtitle: 'Tap a world and explore everything in it',
            isMobile: isMobile,
            textColor: textColor,
          ),
          SizedBox(height: isMobile ? 14 : 20),
          LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final cols = w >= 1100
                  ? 4
                  : w >= 720
                      ? 3
                      : 2;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: entries.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 14,
                  mainAxisExtent: isMobile ? 86 : 104,
                ),
                itemBuilder: (context, i) {
                  final e = entries[i];
                  return _GenreTile(
                    label: e.value,
                    count: e.count,
                    isDark: isDark,
                    onTap: () => context.push(
                      '/tag-feed/genre/${Uri.encodeComponent(e.value)}',
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Topic cloud — top 12 visible by default, "Show all" reveals the rest.
  // No # prefix; the section header carries the meaning.
  // ---------------------------------------------------------------------------
  Widget _buildTagCloudSection({
    required List<FacetEntry> entries,
    required bool isDark,
    required Color textColor,
    required double hPad,
  }) {
    const initial = 12;
    final overflow = entries.length - initial;
    final visible = _allTagsExpanded || entries.length <= initial
        ? entries
        : entries.take(initial).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, 28, hPad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DiscoveryHeader(
            icon: CupertinoIcons.number,
            iconColor: const Color(0xFFEC4899),
            title: 'Topics',
            subtitle: 'Find stories by what they\'re about',
            isMobile: false,
            textColor: textColor,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in visible)
                _buildFacetChip(
                  label: e.value,
                  count: e.count,
                  isDark: isDark,
                  textColor: textColor,
                  onTap: () => context.push(
                    '/tag-feed/tag/${Uri.encodeComponent(e.value)}',
                  ),
                ),
              if (overflow > 0)
                GestureDetector(
                  onTap: () =>
                      setState(() => _allTagsExpanded = !_allTagsExpanded),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.04)
                          : Colors.black.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.10)
                            : Colors.black.withValues(alpha: 0.10),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _allTagsExpanded
                              ? 'Show fewer'
                              : 'Show all $overflow more',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: textColor.withValues(alpha: 0.75),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          _allTagsExpanded
                              ? CupertinoIcons.chevron_up
                              : CupertinoIcons.chevron_down,
                          size: 12,
                          color: textColor.withValues(alpha: 0.6),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Results
  // ---------------------------------------------------------------------------

  /// Universal results: matching tag/genre chips → People → Stories,
  /// each as its own section with a header and count. Mirrors the
  /// pattern Slack / Linear / GitHub use for command-bar search —
  /// information scent first, drill-down second.
  Widget _buildResults(
    bool isDark,
    Color textColor,
    double hPad,
    double width,
  ) {
    if (_searching && _results.isEmpty && _users.isEmpty) {
      return const Center(child: CupertinoActivityIndicator());
    }
    final matchingFacets = _matchingFacetSuggestions();
    final hasAnything =
        _results.isNotEmpty || _users.isNotEmpty || matchingFacets.isNotEmpty;
    if (!hasAnything) {
      return _buildNoResults(textColor);
    }

    final isMobile = Breakpoints.isMobile(width);
    final showFacets = matchingFacets.isNotEmpty;
    final showAuthors = _showAuthors && _users.isNotEmpty;
    final showStories = _showStories && _results.isNotEmpty;

    return CustomScrollView(
      slivers: [
        if (showFacets)
          SliverToBoxAdapter(
            child: _buildSectionHeader('Browse', null, textColor, hPad),
          ),
        if (showFacets)
          SliverToBoxAdapter(
            child: _buildFacetSuggestionStrip(
                matchingFacets, isDark, textColor, hPad),
          ),
        if (showAuthors)
          SliverToBoxAdapter(
            child: _buildSectionHeader(
                'People', _users.length, textColor, hPad),
          ),
        if (showAuthors)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 12),
            sliver: SliverList.separated(
              itemCount: _users.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, i) =>
                  _buildUserRow(_users[i], isDark, textColor),
            ),
          ),
        if (showStories)
          SliverToBoxAdapter(
            child: _buildSectionHeader(
                'Stories', _results.length, textColor, hPad),
          ),
        if (showStories)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 32),
            sliver: isMobile
                ? SliverList.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 14),
                    itemBuilder: (context, i) =>
                        _buildStoryRow(_results[i], isDark, textColor),
                  )
                : SliverGrid.builder(
                    itemCount: _results.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 20,
                      mainAxisSpacing: 14,
                      mainAxisExtent: 118,
                    ),
                    itemBuilder: (context, i) =>
                        _buildStoryCard(_results[i], isDark, textColor),
                  ),
          ),
      ],
    );
  }

  /// Section header with optional count badge — used to break the result
  /// list into Browse / People / Stories.
  Widget _buildSectionHeader(
    String title,
    int? count,
    Color textColor,
    double hPad,
  ) {
    final subtle = textColor.withValues(alpha: 0.5);
    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 8),
      child: Row(
        children: [
          Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: textColor.withValues(alpha: 0.85),
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text(
              '$count',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: subtle,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUserRow(PublicUser user, bool isDark, Color textColor) {
    final subtle = textColor.withValues(alpha: 0.55);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        _commitSearch(_query.isEmpty ? (user.name ?? '') : _query);
        context.push('/u/${user.id}', extra: user);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            _UserAvatar(
                user: user, isDark: isDark, textColor: textColor, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name ?? 'Unnamed',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    user.postsCount == 1
                        ? '1 story'
                        : '${user.postsCount} stories',
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

  /// Genre / tag / type chips whose label substring-matches the query.
  /// Shown above the result rows so a query like "fantasy" surfaces a
  /// browse-the-genre jump-in next to the per-story hits — diversification
  /// across kinds, not just within stories.
  List<({String kind, String label, int count})> _matchingFacetSuggestions() {
    final q = _query.toLowerCase();
    if (q.isEmpty) return const [];
    final out = <({String kind, String label, int count})>[];
    void collect(String kind, List<FacetEntry> entries) {
      for (final e in entries) {
        if (e.value.toLowerCase().contains(q)) {
          out.add((kind: kind, label: e.value, count: e.count));
        }
      }
    }
    collect('genre', _facets.genres);
    collect('tag', _facets.tags);
    collect('type', _facets.writingTypes);
    return out.take(8).toList();
  }

  Widget _buildFacetSuggestionStrip(
    List<({String kind, String label, int count})> entries,
    bool isDark,
    Color textColor,
    double hPad,
  ) {
    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: entries
            .map((e) => _buildFacetChip(
                  label: e.kind == 'tag' ? '#${e.label}' : e.label,
                  count: e.count,
                  isDark: isDark,
                  textColor: textColor,
                  onTap: () => context.push(
                    '/tag-feed/${e.kind}/${Uri.encodeComponent(e.label)}',
                  ),
                ))
            .toList(),
      ),
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
    if (item.imageUrl.isEmpty && item.imageMeta == null) return placeholder;
    return LayoutBuilder(
      builder: (ctx, c) => AppNetworkImage(
        url: item.imageUrl,
        meta: item.imageMeta,
        width: c.maxWidth,
        height: c.maxHeight.isFinite ? c.maxHeight : null,
        fit: BoxFit.cover,
        errorWidget: placeholder,
      ),
    );
  }

  /// Returns the title as-is; kept as a seam for future inline highlight styling.
  String _highlightedTitle(String title) => title;
}

/// Round avatar for a `PublicUser` — falls back to monogrammed initials
/// when no photo is set. Matches the avatar treatment on the author
/// profile page so the user sees the same identity affordance both
/// places.
class _UserAvatar extends StatelessWidget {
  final PublicUser user;
  final bool isDark;
  final Color textColor;
  final double size;
  const _UserAvatar({
    required this.user,
    required this.isDark,
    required this.textColor,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final url = user.photoUrl;
    final hasImage = url != null && url.isNotEmpty;
    final placeholder = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isDark ? Colors.white12 : Colors.black12,
      ),
      child: Text(
        _initialsOf(user.name ?? '?'),
        style: GoogleFonts.inter(
          fontSize: size * 0.36,
          fontWeight: FontWeight.w700,
          color: textColor,
        ),
      ),
    );
    if (!hasImage) return placeholder;
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: AppNetworkImage(
          url: url,
          meta: user.photoMeta,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorWidget: placeholder,
        ),
      ),
    );
  }

  static String _initialsOf(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final first = parts.first.substring(0, 1).toUpperCase();
    final last =
        parts.length > 1 ? parts.last.substring(0, 1).toUpperCase() : '';
    return '$first$last';
  }
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

/// Section header used across the discovery surface — leads with a colored
/// icon, title in serif Display weight, and a one-line "why care" subtitle.
class _DiscoveryHeader extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool isMobile;
  final Color textColor;

  const _DiscoveryHeader({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.isMobile,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final subtle = textColor.withValues(alpha: 0.55);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: isMobile ? 28 : 34,
          height: isMobile ? 28 : 34,
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.14),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: isMobile ? 15 : 17, color: iconColor),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.playfairDisplay(
                  fontSize: isMobile ? 19 : 23,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                  letterSpacing: -0.4,
                ),
              ),
              Text(
                subtitle,
                style: GoogleFonts.inter(
                  fontSize: isMobile ? 12 : 13,
                  fontWeight: FontWeight.w500,
                  color: subtle,
                  letterSpacing: -0.05,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Single author chip used in the discovery "Authors to follow" strip.
/// Renders an initials avatar in a soft palette derived from the name so the
/// strip never looks monochromatic, even without uploaded photos.
class _AuthorChip extends StatefulWidget {
  final String authorId;
  final String name;
  final bool isDark;
  final Color textColor;
  final VoidCallback onTap;

  const _AuthorChip({
    required this.authorId,
    required this.name,
    required this.isDark,
    required this.textColor,
    required this.onTap,
  });

  @override
  State<_AuthorChip> createState() => _AuthorChipState();
}

class _AuthorChipState extends State<_AuthorChip> {
  bool _hover = false;

  static const _palette = <List<Color>>[
    [Color(0xFF6366F1), Color(0xFF8B5CF6)],
    [Color(0xFFEC4899), Color(0xFFF97316)],
    [Color(0xFF10B981), Color(0xFF06B6D4)],
    [Color(0xFFF59E0B), Color(0xFFEF4444)],
    [Color(0xFF8B5CF6), Color(0xFF3B82F6)],
    [Color(0xFF14B8A6), Color(0xFF22C55E)],
  ];

  String _initials(String n) {
    final parts =
        n.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final first = parts.first.substring(0, 1).toUpperCase();
    final last =
        parts.length > 1 ? parts.last.substring(0, 1).toUpperCase() : '';
    return '$first$last';
  }

  @override
  Widget build(BuildContext context) {
    final colors = _palette[widget.authorId.hashCode.abs() % _palette.length];
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: 88,
          child: Column(
            children: [
              AnimatedScale(
                scale: _hover ? 1.05 : 1.0,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: colors,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: colors.first
                            .withValues(alpha: _hover ? 0.45 : 0.25),
                        blurRadius: _hover ? 22 : 14,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _initials(widget.name),
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                widget.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: widget.textColor,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Visual genre tile — replaces the bare-pill row. Each tile gets a soft
/// gradient sourced from a name-hashed palette so the grid feels editorial
/// rather than algorithmic. Tap routes to the same tag-feed page the chips
/// used.
class _GenreTile extends StatefulWidget {
  final String label;
  final int count;
  final bool isDark;
  final VoidCallback onTap;

  const _GenreTile({
    required this.label,
    required this.count,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<_GenreTile> createState() => _GenreTileState();
}

class _GenreTileState extends State<_GenreTile> {
  bool _hover = false;

  static const _palettes = <List<Color>>[
    [Color(0xFF6366F1), Color(0xFF1E1B4B)],
    [Color(0xFFEC4899), Color(0xFF500724)],
    [Color(0xFF10B981), Color(0xFF064E3B)],
    [Color(0xFFF59E0B), Color(0xFF78350F)],
    [Color(0xFF06B6D4), Color(0xFF164E63)],
    [Color(0xFF8B5CF6), Color(0xFF4C1D95)],
    [Color(0xFFEF4444), Color(0xFF7F1D1D)],
    [Color(0xFF22C55E), Color(0xFF14532D)],
  ];

  @override
  Widget build(BuildContext context) {
    final p = _palettes[widget.label.hashCode.abs() % _palettes.length];
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.fromLTRB(18, 14, 16, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: p,
            ),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: p.first.withValues(alpha: 0.40),
                      blurRadius: 26,
                      offset: const Offset(0, 14),
                      spreadRadius: -4,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: p.last.withValues(alpha: 0.30),
                      blurRadius: 14,
                      offset: const Offset(0, 8),
                      spreadRadius: -4,
                    ),
                  ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.label[0].toUpperCase() + widget.label.substring(1),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: -0.3,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.count == 1
                          ? '1 story'
                          : '${widget.count} stories',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.72),
                      ),
                    ),
                  ],
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: _hover ? 0.22 : 0.14),
                ),
                child: const Icon(
                  CupertinoIcons.arrow_right,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
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
