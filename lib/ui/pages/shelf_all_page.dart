import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';
import 'package:inkspacex/ui/widgets/author_link.dart';

/// Drill-down page for a home-feed shelf. Fetches its own items from
/// the backend keyed by `railId`, with cursor pagination — items load
/// as the user scrolls. Only published / public writings are returned
/// because the underlying `/api/feed/` endpoint already enforces that.
class ShelfAllPage extends StatefulWidget {
  final String railId;
  final String title;

  const ShelfAllPage({
    super.key,
    required this.railId,
    required this.title,
  });

  @override
  State<ShelfAllPage> createState() => _ShelfAllPageState();
}

class _ShelfAllPageState extends State<ShelfAllPage> {
  static const _pageSize = 24;
  static const _scrollThreshold = 600.0;

  final List<FeedItemModel> _items = [];
  final Set<String> _seenIds = {};
  String? _cursor;
  bool _hasMore = true;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFirstPage());
  }

  ApiDataService get _api => context.read<AuthProvider>().dataService;

  String get _sort {
    switch (widget.railId) {
      case 'new_release':
        return 'recent';
      case 'trending_now':
      case 'top_10_week':
      case 'featured':
      case 'editor_picks':
      case 'hidden_gems':
      default:
        return 'trending';
    }
  }

  bool get _supportsPagination =>
      widget.railId != 'recommendation' && widget.railId != 'continue_reading';

  Future<void> _loadFirstPage() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final items = await _fetch(cursor: null);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(items);
        _seenIds
          ..clear()
          ..addAll(items.map((e) => e.id));
        _cursor = items.isNotEmpty ? items.last.id : null;
        _hasMore = _supportsPagination && items.length >= _pageSize;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Couldn\'t load. Pull to retry.';
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _isLoadingMore || _isLoading) return;
    setState(() => _isLoadingMore = true);
    try {
      final next = await _fetch(cursor: _cursor);
      if (!mounted) return;
      final fresh = next.where((e) => _seenIds.add(e.id)).toList();
      setState(() {
        _items.addAll(fresh);
        if (fresh.isNotEmpty) _cursor = fresh.last.id;
        _hasMore = next.length >= _pageSize && fresh.isNotEmpty;
        _isLoadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingMore = false;
        _hasMore = false;
      });
    }
  }

  Future<List<FeedItemModel>> _fetch({String? cursor}) async {
    if (widget.railId == 'continue_reading') {
      // Continue Reading is computed client-side from reading-progress;
      // pull the provider's current set rather than re-hitting the API.
      return context.read<FeedProvider>().getContinueReadingItems();
    }
    if (widget.railId == 'recommendation') {
      final res = await _api.getRecommendations(limit: 50);
      return res.items;
    }
    final auth = context.read<AuthProvider>();
    final prefs = auth.currentUser?.preferences;
    if (prefs == null) return const [];
    final page = await _api.getPersonalizedFeed(
      prefs,
      pageSize: _pageSize,
      cursor: cursor,
      sort: _sort,
      currentUserId: auth.currentUser?.id,
    );
    return page.items;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFF8F9FA);
    final width = MediaQuery.sizeOf(context).width;

    final crossAxisCount = width >= 1200
        ? 5
        : width >= 900
            ? 4
            : width >= 600
                ? 3
                : 2;
    final hPadding = width >= 900 ? 32.0 : 16.0;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          widget.title,
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _buildBody(
        textColor: textColor,
        isDark: isDark,
        crossAxisCount: crossAxisCount,
        hPadding: hPadding,
      ),
    );
  }

  Widget _buildBody({
    required Color textColor,
    required bool isDark,
    required int crossAxisCount,
    required double hPadding,
  }) {
    if (_isLoading && _items.isEmpty) {
      return const Center(child: AppSpinner());
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: textColor.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _loadFirstPage,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          'Nothing here yet.',
          style: GoogleFonts.inter(
            fontSize: 14,
            color: textColor.withValues(alpha: 0.6),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFirstPage,
      color: textColor,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels >=
              n.metrics.maxScrollExtent - _scrollThreshold) {
            _loadMore();
          }
          return false;
        },
        child: GridView.builder(
          padding: EdgeInsets.fromLTRB(hPadding, 8, hPadding, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 20,
            crossAxisSpacing: 16,
            childAspectRatio: 0.56,
          ),
          itemCount: _items.length + (_isLoadingMore ? crossAxisCount : 0),
          itemBuilder: (context, index) {
            if (index >= _items.length) {
              return const Center(child: AppSpinner());
            }
            final item = _items[index];
            return _ShelfCard(
              item: item,
              isDark: isDark,
              onTap: () =>
                  context.push('/post/${item.id}', extra: item),
            );
          },
        ),
      ),
    );
  }
}

class _ShelfCard extends StatelessWidget {
  final FeedItemModel item;
  final bool isDark;
  final VoidCallback onTap;

  const _ShelfCard({
    required this.item,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = textColor.withValues(alpha: 0.55);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: isDark
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AspectRatio(
                  aspectRatio: item.imageMeta?.aspectRatio ?? 2 / 3,
                  child: (item.imageUrl.isNotEmpty || item.imageMeta != null)
                      ? LayoutBuilder(
                          builder: (ctx, c) => AppNetworkImage(
                            url: item.imageUrl,
                            meta: item.imageMeta,
                            width: c.maxWidth,
                            height: c.maxHeight,
                            fit: BoxFit.cover,
                            errorWidget: _placeholder(),
                          ),
                        )
                      : _placeholder(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              item.title,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: textColor,
                height: 1.25,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            AuthorLink(
              name: item.author,
              authorId: item.authorId,
              style: GoogleFonts.inter(
                fontSize: 11,
                color: subtle,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    final initial = item.title.isNotEmpty ? item.title[0].toUpperCase() : '?';
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF1A1A2E), const Color(0xFF16213E)]
              : [const Color(0xFFE8EDF2), const Color(0xFFD5DCE5)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: GoogleFonts.playfairDisplay(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: isDark
              ? Colors.white.withValues(alpha: 0.2)
              : Colors.black.withValues(alpha: 0.15),
        ),
      ),
    );
  }
}
