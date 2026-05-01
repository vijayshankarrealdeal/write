import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

/// Which kind of facet the page is drilling into. Drives the API call
/// (`getFeedByTag` vs `getFeedByGenre`) and the page title.
enum TagFeedKind { tag, genre, writingType }

/// Drill-down feed for a single tag, genre, or writing-type. Reachable
/// from any chip on a feed card or from the Explore page. Lays out the
/// same column-of-cards as the main feed and reuses the cursor-based
/// pagination shape returned by the backend.
///
/// Test seam: tests inject [loader] to bypass the real API client.
typedef TagFeedLoader = Future<ApiFeedPage> Function({
  required String sort,
  String? cursor,
});

class TagFeedPage extends StatefulWidget {
  final TagFeedKind kind;
  final String value;
  final TagFeedLoader? loader;

  const TagFeedPage({
    super.key,
    required this.kind,
    required this.value,
    this.loader,
  });

  @override
  State<TagFeedPage> createState() => _TagFeedPageState();
}

class _TagFeedPageState extends State<TagFeedPage> {
  static const _sorts = ['recent', 'trending', 'top'];

  String _sort = 'recent';
  final List<FeedItemModel> _items = [];
  String? _cursor;
  bool _hasMore = true;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  TagFeedLoader _resolveLoader() {
    final injected = widget.loader;
    if (injected != null) return injected;
    final api = context.read<AuthProvider>().dataService;
    return ({required String sort, String? cursor}) {
      switch (widget.kind) {
        case TagFeedKind.tag:
        case TagFeedKind.writingType:
          // No dedicated by-writing-type endpoint — the multi-value feed
          // params handle it for the main feed; for a drill-down view
          // we treat the writing-type label like a tag (matches the
          // "show me more like this label" intent and the way the chip
          // is rendered on the card).
          return api.getFeedByTag(widget.value, sort: sort, cursor: cursor);
        case TagFeedKind.genre:
          return api.getFeedByGenre(widget.value, sort: sort, cursor: cursor);
      }
    };
  }

  Future<void> _reload() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
      _items.clear();
      _cursor = null;
      _hasMore = true;
    });
    try {
      final page = await _resolveLoader()(sort: _sort);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.nextCursor;
        _hasMore = page.items.isNotEmpty;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore || _isLoading) return;
    setState(() => _isLoadingMore = true);
    try {
      final page = await _resolveLoader()(sort: _sort, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.nextCursor;
        _hasMore = page.items.isNotEmpty;
        _isLoadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingMore = false);
    }
  }

  void _setSort(String sort) {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    _reload();
  }

  String get _kindLabel {
    switch (widget.kind) {
      case TagFeedKind.tag:
        return '#';
      case TagFeedKind.genre:
        return 'Genre';
      case TagFeedKind.writingType:
        return 'Writing';
    }
  }

  String get _title {
    switch (widget.kind) {
      case TagFeedKind.tag:
        return '#${widget.value}';
      case TagFeedKind.genre:
      case TagFeedKind.writingType:
        return widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white54 : Colors.black45;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFF8F9FA);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _title,
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              _kindLabel,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: subtleColor,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          _SortBar(
            current: _sort,
            sorts: _sorts,
            onChanged: _setSort,
            isDark: isDark,
          ),
          Expanded(
            child: _buildBody(textColor, subtleColor, isDark),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(Color textColor, Color subtleColor, bool isDark) {
    if (_isLoading) {
      return const Center(child: AppSpinner());
    }
    if (_error != null && _items.isEmpty) {
      return _EmptyState(
        icon: CupertinoIcons.exclamationmark_circle,
        title: 'Couldn\'t load',
        subtitle: 'Pull to retry, or pick another sort.',
        textColor: textColor,
        subtleColor: subtleColor,
      );
    }
    if (_items.isEmpty) {
      return _EmptyState(
        icon: CupertinoIcons.search,
        title: 'Nothing here yet',
        subtitle: widget.kind == TagFeedKind.tag
            ? 'No published writing tagged #${widget.value}.'
            : 'No published writing in ${widget.value}.',
        textColor: textColor,
        subtleColor: subtleColor,
        action: TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Back'),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _reload,
      color: textColor,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
            _loadMore();
          }
          return false;
        },
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: _items.length + (_isLoadingMore ? 1 : 0),
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, idx) {
            if (idx >= _items.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: AppSpinner()),
              );
            }
            return _DrillCard(
              item: _items[idx],
              isDark: isDark,
              onTap: () =>
                  context.push('/post/${_items[idx].id}', extra: _items[idx]),
            );
          },
        ),
      ),
    );
  }
}

/// Compact segmented sort selector pinned beneath the app bar.
class _SortBar extends StatelessWidget {
  final String current;
  final List<String> sorts;
  final ValueChanged<String> onChanged;
  final bool isDark;

  const _SortBar({
    required this.current,
    required this.sorts,
    required this.onChanged,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: sorts.map((s) {
          final selected = s == current;
          return GestureDetector(
            onTap: () => onChanged(s),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? (isDark ? Colors.white : Colors.black)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.04)),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _label(s),
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? (isDark ? Colors.black : Colors.white)
                      : textColor.withValues(alpha: 0.7),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  String _label(String s) {
    switch (s) {
      case 'recent':
        return 'Recent';
      case 'trending':
        return 'Trending';
      case 'top':
        return 'Top';
      default:
        return s;
    }
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color textColor;
  final Color subtleColor;
  final Widget? action;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.textColor,
    required this.subtleColor,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: subtleColor),
            const SizedBox(height: 12),
            Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: subtleColor,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[
              const SizedBox(height: 12),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Card used for drill-down rows. Visually similar to the search results
/// row — image, title, author, brief description.
class _DrillCard extends StatelessWidget {
  final FeedItemModel item;
  final bool isDark;
  final VoidCallback onTap;

  const _DrillCard({
    required this.item,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cardColor = isDark ? const Color(0xFF141414) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = isDark ? Colors.white60 : Colors.black54;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 96,
                height: 96,
                child: (item.imageUrl.isNotEmpty || item.imageMeta != null)
                    ? AppNetworkImage(
                        url: item.imageUrl,
                        meta: item.imageMeta,
                        width: 96,
                        height: 96,
                        fit: BoxFit.cover,
                      )
                    : Container(color: borderColor),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (item.author.isNotEmpty)
                        Text(
                          item.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: subtle,
                          ),
                        ),
                      if (item.description.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          item.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: subtle.withValues(alpha: 0.85),
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
