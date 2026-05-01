import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/ui/utilities/responsive_layout.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';
import 'package:inkspacex/ui/widgets/feed_filter_chip_row.dart';

class Feed extends StatefulWidget {
  const Feed({super.key});

  @override
  State<Feed> createState() => _FeedState();
}

class _FeedState extends State<Feed> with WidgetsBindingObserver {
  bool get isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFeed());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Twitter / Instagram pattern: probe the server for new items every
  /// time the app comes back to the foreground. The probe stays silent —
  /// any new items surface via the "X new posts" pill, never via a
  /// disorienting auto-prepend onto the user's scroll position.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;
    final feed = context.read<FeedProvider>();
    if (feed.items.isEmpty) return;
    feed.silentRefresh();
  }

  void _loadFeed() async {
    final auth = context.read<AuthProvider>();
    final feed = context.read<FeedProvider>();
    final prefs = auth.currentUser?.preferences ?? const UserPreferences();
    final userId = auth.currentUser?.id;
    try {
      if (feed.items.isNotEmpty) {
        feed.silentRefresh();
      } else {
        await feed.loadFeedIfNeeded(prefs, userId: userId);
      }
      if (userId != null) {
        feed.loadReadingProgress(userId);
      }
      // Personalised recommendations are an additive layer over the
      // generic feed — kicked off in parallel so the initial render
      // never waits on the AI engine.
      feed.loadRecommendations();
      _precacheTop(feed);
    } catch (e) {
      debugPrint("Error loading feed: $e");
    }
  }

  /// Warm the cache for the first slice of feed covers so the user never
  /// sees a blurhash placeholder for above-the-fold content. Runs after the
  /// next frame so we use the live MediaQuery (DPR + width) as ground truth.
  void _precacheTop(FeedProvider feed) {
    if (!mounted || feed.items.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final width = MediaQuery.sizeOf(context).width;
      // Cards on a phone fill the column; on desktop the grid splits the
      // viewport so the per-card render is narrower. 720 matches the same
      // breakpoint the feed renderer uses elsewhere.
      final perCardWidth = width >= 720 ? width / 2 : width;
      for (final item in feed.items.take(6)) {
        AppNetworkImage.precache(
          context,
          url: item.imageUrl,
          meta: item.imageMeta,
          width: perCardWidth,
        );
      }
    });
  }

  Future<void> _onRefresh() async {
    final auth = context.read<AuthProvider>();
    final feed = context.read<FeedProvider>();
    final prefs = auth.currentUser?.preferences ?? const UserPreferences();
    await Future.wait([
      feed.loadFeed(
        prefs,
        forceRefresh: true,
        userId: auth.currentUser?.id,
      ),
      feed.loadRecommendations(),
    ]);
    _precacheTop(feed);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = Breakpoints.isMobile(width);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFF8F9FA);

    return Consumer2<FeedProvider, AuthProvider>(
      builder: (context, feed, auth, _) {
        if (feed.isLoading && feed.items.isEmpty) {
          return Scaffold(
            backgroundColor: bgColor,
            body: _buildLoadingSpinner(),
          );
        }

        if (feed.items.isEmpty && !feed.isLoading) {
          return Scaffold(
            backgroundColor: bgColor,
            body: _FeedEmptyState(
              isDark: isDark,
              error: feed.error,
              onRefresh: _onRefresh,
              onCustomize: () => context.push('/feed-preferences'),
              onWrite: () => context.push('/editor'),
            ),
          );
        }

        return Scaffold(
          backgroundColor: bgColor,
          body: Stack(
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.metrics.pixels >=
                      notification.metrics.maxScrollExtent - 800) {
                    // 800px lookahead gives loadMore + precache time to complete
                    // before the user actually scrolls into the new tiles.
                    final before = feed.items.length;
                    feed.loadMore(userId: auth.currentUser?.id).then((_) {
                      if (!mounted || feed.items.length <= before) return;
                      final width = MediaQuery.sizeOf(context).width;
                      final perCardWidth = width >= 720 ? width / 2 : width;
                      for (final item in feed.items.skip(before).take(6)) {
                        AppNetworkImage.precache(
                          context,
                          url: item.imageUrl,
                          meta: item.imageMeta,
                          width: perCardWidth,
                        );
                      }
                    });
                  }
                  return false;
                },
                child: RefreshIndicator(
                  onRefresh: _onRefresh,
                  color: textColor,
                  child: _buildShelfHome(feed, auth, textColor, width, isMobile),
                ),
              ),
              _NewPostsPill(
                count: feed.pendingNewItemsCount,
                isDark: isDark,
                onTap: () => _applyPendingAndScrollToTop(feed),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _applyPendingAndScrollToTop(FeedProvider feed) async {
    if (feed.pendingNewItemsCount == 0) return;
    HapticFeedback.selectionClick();
    feed.applyPendingNewItems();
    final controller = PrimaryScrollController.maybeOf(context);
    if (controller == null || !controller.hasClients) return;
    await controller.animateTo(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildLoadingSpinner() {
    final color = isDark ? Colors.white : const Color(0xFF0F172A);
    return Center(child: AppSpinner(size: 32, color: color));
  }

  // ==========================================================================
  // Shelf-based homepage (Apple Books style) — works for mobile & desktop
  // ==========================================================================
  Widget _buildShelfHome(
    FeedProvider feed,
    AuthProvider auth,
    Color textColor,
    double width,
    bool isMobile,
  ) {
    final all = feed.groupedItems;
    if (all.isEmpty) {
      return _buildLoadingSpinner();
    }

    final continueReading = feed.getContinueReadingItems();
    final userGenres = auth.currentUser?.preferences.preferredGenres
            .map((g) => g.toLowerCase())
            .toSet() ??
        <String>{};

    // Recommendations come from the AI engine when available. While
    // they're loading (or if the call failed) we fall back to the
    // genre-overlap heuristic so the shelf is never empty.
    final engineRecommended = feed.recommendedItems;
    final List<FeedItemModel> recommended;
    if (engineRecommended.isNotEmpty) {
      recommended = engineRecommended.take(12).toList();
    } else if (userGenres.isEmpty) {
      recommended = all.take(12).toList();
    } else {
      recommended = all
          .where((i) =>
              i.genres.any((g) => userGenres.contains(g.toLowerCase())))
          .take(12)
          .toList();
    }
    final hasEngineRecs = engineRecommended.isNotEmpty;

    final trending = [...all]
      ..sort((a, b) => b.likesCount.compareTo(a.likesCount));
    final topTen = trending.take(10).toList();

    final now = DateTime.now();
    final hiddenGems = all
        .where((i) =>
            i.likesCount < 50 && now.difference(i.createdAt).inDays < 60)
        .take(14)
        .toList();

    final editorsPicks = all.where((i) => i.sections.length > 1).toList()
      ..sort((a, b) => b.sections.length.compareTo(a.sections.length));

    final newest = [...all]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final hPadding = isMobile ? 16.0 : (width > 1400 ? 48.0 : 32.0);
    final cardWidth = isMobile ? 130.0 : 180.0;
    // cover aspect 3/4 → height = w*4/3; plus ~82px for labels/padding.
    final shelfHeight = (cardWidth * 4 / 3) + 86;
    final rankedCardWidth = isMobile ? 210.0 : 270.0;
    final rankedNumeralWidth = isMobile ? 64.0 : 92.0;
    // ranked cover width = (rankedCardWidth - numeralWidth) → *4/3 + labels
    final rankedShelfHeight =
        ((rankedCardWidth - rankedNumeralWidth) * 4 / 3) + 64;

    if (feed.hasActiveFilters) {
      return _buildFilteredView(feed, auth, textColor, hPadding, isMobile);
    }

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                hPadding, isMobile ? 12 : 24, hPadding, 8),
            child: _buildHero(all.first, auth, feed, isMobile),
          ),
        ),

        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 12, bottom: 4),
            child: FeedFilterChipRow(),
          ),
        ),

        if (continueReading.isNotEmpty)
          SliverToBoxAdapter(
            child: _buildShelf(
              title: 'Continue reading',
              items: continueReading,
              textColor: textColor,
              hPadding: hPadding,
              cardWidth: cardWidth,
              shelfHeight: shelfHeight,
              isMobile: isMobile,
            ),
          ),

        if (recommended.isNotEmpty)
          SliverToBoxAdapter(
            child: _buildShelf(
              title: hasEngineRecs || userGenres.isNotEmpty
                  ? 'Recommended for you'
                  : 'Featured picks',
              subtitle: hasEngineRecs
                  ? 'Personalised by your reading patterns'
                  : (userGenres.isEmpty
                      ? null
                      : 'Based on your reading preferences'),
              items: recommended,
              textColor: textColor,
              hPadding: hPadding,
              cardWidth: cardWidth,
              shelfHeight: shelfHeight,
              isMobile: isMobile,
              feed: feed,
              logImpressions: hasEngineRecs,
            ),
          ),

        if (trending.length >= 3)
          SliverToBoxAdapter(
            child: _buildShelf(
              title: 'Trending now',
              items: trending.take(14).toList(),
              textColor: textColor,
              hPadding: hPadding,
              cardWidth: cardWidth,
              shelfHeight: shelfHeight,
              isMobile: isMobile,
            ),
          ),

        if (topTen.length >= 3)
          SliverToBoxAdapter(
            child: _buildTopTenShelf(
              items: topTen,
              textColor: textColor,
              hPadding: hPadding,
              cardWidth: rankedCardWidth,
              numeralWidth: rankedNumeralWidth,
              shelfHeight: rankedShelfHeight,
              isMobile: isMobile,
            ),
          ),

        if (hiddenGems.isNotEmpty)
          SliverToBoxAdapter(
            child: _buildShelf(
              title: 'Discover hidden gems',
              subtitle: 'Fresh voices worth exploring',
              items: hiddenGems,
              textColor: textColor,
              hPadding: hPadding,
              cardWidth: cardWidth,
              shelfHeight: shelfHeight,
              isMobile: isMobile,
            ),
          ),

        if (editorsPicks.isNotEmpty)
          SliverToBoxAdapter(
            child: _buildShelf(
              title: "Editor's picks",
              items: editorsPicks.take(14).toList(),
              textColor: textColor,
              hPadding: hPadding,
              cardWidth: cardWidth,
              shelfHeight: shelfHeight,
              isMobile: isMobile,
            ),
          ),

        SliverToBoxAdapter(
          child: _buildShelf(
            title: 'New releases',
            items: newest.take(14).toList(),
            textColor: textColor,
            hPadding: hPadding,
            cardWidth: cardWidth,
            shelfHeight: shelfHeight,
            isMobile: isMobile,
          ),
        ),

        if (feed.isLoadingMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(bottom: 32, top: 16),
              child: Center(child: AppSpinner()),
            ),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }

  /// Single-list view shown while one or more filter chips are active.
  /// We collapse the multi-shelf layout because shelves like "Trending"
  /// and "Editor's picks" stop being meaningful inside a filtered slice.
  Widget _buildFilteredView(
    FeedProvider feed,
    AuthProvider auth,
    Color textColor,
    double hPadding,
    bool isMobile,
  ) {
    final filtered = feed.filteredItems;
    final isEmpty = filtered.isEmpty &&
        !feed.isLoadingFiltered &&
        feed.filteredError == null;

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 800) {
          feed.loadMoreFiltered();
        }
        return false;
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  hPadding, isMobile ? 12 : 24, hPadding, 4),
              child: _buildFilterSummary(feed, textColor, isMobile),
            ),
          ),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 4, bottom: 8),
              child: FeedFilterChipRow(),
            ),
          ),
          if (feed.isLoadingFiltered && filtered.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: AppSpinner()),
            )
          else if (isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _buildFilteredEmpty(feed, textColor, isMobile),
            )
          else if (isMobile)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: hPadding),
              sliver: _buildMobileList(filtered, auth, feed),
            )
          else
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: hPadding),
              sliver: _buildDesktopGrid(
                filtered,
                auth,
                feed,
                MediaQuery.sizeOf(context).width,
              ),
            ),
          if (feed.isLoadingMoreFiltered)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: 32, top: 16),
                child: Center(child: AppSpinner()),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }

  Widget _buildFilterSummary(
    FeedProvider feed,
    Color textColor,
    bool isMobile,
  ) {
    final n = feed.filterGenres.length +
        feed.filterTags.length +
        feed.filterWritingTypes.length;
    final count = feed.filteredItems.length;
    final loading = feed.isLoadingFiltered && count == 0;
    final summary = loading
        ? 'Loading…'
        : '$count result${count == 1 ? '' : 's'} for $n filter${n == 1 ? '' : 's'}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            summary,
            style: GoogleFonts.inter(
              fontSize: isMobile ? 14 : 15,
              fontWeight: FontWeight.w600,
              color: textColor.withValues(alpha: 0.75),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilteredEmpty(
    FeedProvider feed,
    Color textColor,
    bool isMobile,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.tray,
            size: 48,
            color: textColor.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 12),
          Text(
            'No matches',
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Try fewer filters, or a different combination.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: textColor.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: feed.clearFilters,
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }

  Widget _buildHero(
    FeedItemModel item,
    AuthProvider auth,
    FeedProvider feed,
    bool isMobile,
  ) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = textColor.withValues(alpha: 0.6);

    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF2563EB).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'FEATURED',
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF2563EB),
          letterSpacing: 1.4,
        ),
      ),
    );

    final titleText = Text(
      item.title,
      style: GoogleFonts.playfairDisplay(
        fontSize: isMobile ? 28 : 44,
        fontWeight: FontWeight.w700,
        color: textColor,
        height: 1.05,
        letterSpacing: -0.6,
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );

    final authorText = Text(
      'by ${item.author}',
      style: GoogleFonts.inter(
        fontSize: isMobile ? 13 : 14,
        color: subtle,
        fontWeight: FontWeight.w500,
      ),
    );

    final descriptionText = item.description.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: EdgeInsets.only(top: isMobile ? 14 : 20),
            child: Text(
              item.description,
              style: GoogleFonts.inter(
                fontSize: isMobile ? 13 : 15,
                color: subtle,
                height: 1.55,
              ),
              maxLines: isMobile ? 2 : 3,
              overflow: TextOverflow.ellipsis,
            ),
          );

    final actions = Row(
      children: [
        CupertinoButton(
          padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 18 : 28, vertical: isMobile ? 11 : 14),
          color: isDark ? Colors.white : Colors.black,
          borderRadius: BorderRadius.circular(10),
          onPressed: () => _openPost(item),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.book_fill,
                size: 15,
                color: isDark ? Colors.black : Colors.white,
              ),
              const SizedBox(width: 8),
              Text(
                'Read now',
                style: GoogleFonts.inter(
                  color: isDark ? Colors.black : Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: isMobile ? 13 : 14,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Consumer<AuthProvider>(
          builder: (c, authState, _) {
            final saved =
                authState.currentUser?.savedPosts.contains(item.id) ?? false;
            return CupertinoButton(
              padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 14 : 22,
                  vertical: isMobile ? 11 : 14),
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
              onPressed: () => authState.toggleSave(item.id),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    saved
                        ? CupertinoIcons.bookmark_fill
                        : CupertinoIcons.bookmark,
                    size: 15,
                    color: saved ? const Color(0xFF2563EB) : textColor,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    saved ? 'Saved' : 'Save',
                    style: GoogleFonts.inter(
                      color: textColor,
                      fontWeight: FontWeight.w600,
                      fontSize: isMobile ? 13 : 14,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );

    // The frame uses a fixed, predictable ratio. The image renders inside
    // it with BoxFit.contain so the author's full artwork is always visible,
    // and the empty space is filled by a heavily blurred copy of the same
    // image — ambient color matches the cover instead of leaving grey bars.
    final heroRatio = isMobile ? 16 / 10 : 4 / 5;
    final hasImage = item.imageUrl.isNotEmpty || item.imageMeta != null;
    final cover = AspectRatio(
      aspectRatio: heroRatio,
      child: LayoutBuilder(
        builder: (ctx, c) {
          if (!hasImage) {
            return _buildPlaceholderCover(item.title, isMobile ? 180 : 380);
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: 32,
                  sigmaY: 32,
                  tileMode: TileMode.decal,
                ),
                child: AppNetworkImage(
                  url: item.imageUrl,
                  meta: item.imageMeta,
                  width: c.maxWidth,
                  height: c.maxHeight,
                  fit: BoxFit.cover,
                  errorWidget: const SizedBox.shrink(),
                ),
              ),
              Container(
                color: (isDark ? Colors.black : Colors.white)
                    .withValues(alpha: 0.18),
              ),
              AppNetworkImage(
                url: item.imageUrl,
                meta: item.imageMeta,
                width: c.maxWidth,
                height: c.maxHeight,
                fit: BoxFit.contain,
                errorWidget:
                    _buildPlaceholderCover(item.title, isMobile ? 180 : 380),
              ),
            ],
          );
        },
      ),
    );

    return GestureDetector(
      onTap: () => _openPost(item),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(isMobile ? 16 : 24),
            color: isDark ? const Color(0xFF141414) : Colors.white,
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.black.withValues(alpha: 0.06),
            ),
            boxShadow: isDark
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
          ),
          clipBehavior: Clip.antiAlias,
          child: isMobile
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    cover,
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          badge,
                          const SizedBox(height: 12),
                          titleText,
                          const SizedBox(height: 6),
                          authorText,
                          descriptionText,
                          const SizedBox(height: 18),
                          actions,
                        ],
                      ),
                    ),
                  ],
                )
              : SizedBox(
                  height: 380,
                  child: Row(
                    children: [
                      cover,
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(40),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              badge,
                              const SizedBox(height: 16),
                              titleText,
                              const SizedBox(height: 12),
                              authorText,
                              descriptionText,
                              const SizedBox(height: 28),
                              actions,
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildShelf({
    required String title,
    String? subtitle,
    required List<FeedItemModel> items,
    required Color textColor,
    required double hPadding,
    required double cardWidth,
    required double shelfHeight,
    required bool isMobile,
    FeedProvider? feed,
    bool logImpressions = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(top: isMobile ? 24 : 32, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: hPadding),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.inter(
                          fontSize: isMobile ? 18 : 22,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                          letterSpacing: -0.3,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: GoogleFonts.inter(
                            fontSize: isMobile ? 12 : 13,
                            color: textColor.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {},
                    child: Row(
                      children: [
                        Text(
                          'See all',
                          style: GoogleFonts.inter(
                            fontSize: isMobile ? 12 : 13,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF2563EB),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          CupertinoIcons.chevron_right,
                          size: 12,
                          color: Color(0xFF2563EB),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: isMobile ? 12 : 16),
          SizedBox(
            height: shelfHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: hPadding),
              itemCount: items.length,
              separatorBuilder: (_, __) =>
                  SizedBox(width: isMobile ? 12 : 16),
              itemBuilder: (context, index) {
                final item = items[index];
                // Recommendation telemetry: record one impression per
                // (session, item) the first time the card is built.
                // Per-render dedupe lives in FeedProvider so a
                // re-build from a parent setState won't double-count.
                if (logImpressions && feed != null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    feed.recordRecommendationImpression(
                      item,
                      position: index + 1,
                    );
                  });
                }
                return _BookCard(
                  item: item,
                  isDark: isDark,
                  width: cardWidth,
                  isMobile: isMobile,
                  showReason: logImpressions,
                  onTap: () {
                    if (logImpressions && feed != null) {
                      feed.recordRecommendationClick(item, position: index + 1);
                    }
                    _openPost(item);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopTenShelf({
    required List<FeedItemModel> items,
    required Color textColor,
    required double hPadding,
    required double cardWidth,
    required double numeralWidth,
    required double shelfHeight,
    required bool isMobile,
  }) {
    return Padding(
      padding: EdgeInsets.only(top: isMobile ? 24 : 32, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: hPadding),
            child: Text(
              'Top 10 this week',
              style: GoogleFonts.inter(
                fontSize: isMobile ? 18 : 22,
                fontWeight: FontWeight.w700,
                color: textColor,
                letterSpacing: -0.3,
              ),
            ),
          ),
          SizedBox(height: isMobile ? 12 : 16),
          SizedBox(
            height: shelfHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: hPadding),
              itemCount: items.length,
              separatorBuilder: (_, __) =>
                  SizedBox(width: isMobile ? 16 : 24),
              itemBuilder: (context, index) => _RankedBookCard(
                rank: index + 1,
                item: items[index],
                isDark: isDark,
                width: cardWidth,
                numeralWidth: numeralWidth,
                isMobile: isMobile,
                onTap: () => _openPost(items[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContinueReading(
    Color textColor,
    List<FeedItemModel> items,
    bool isMobile,
  ) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isMobile ? 16 : 32,
        0,
        isMobile ? 16 : 32,
        20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.book,
                size: 16,
                color: textColor.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 8),
              Text(
                "CONTINUE READING",
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: textColor.withValues(alpha: 0.4),
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, idx) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final item = items[index];
                return GestureDetector(
                  onTap: () => _openPost(item),
                  child: Container(
                    width: 200,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.black.withValues(alpha: 0.06),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          item.title,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.author,
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: textColor.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeaturedCard(
    FeedItemModel item,
    AuthProvider auth,
    FeedProvider feed,
    bool isMobile,
  ) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white54 : Colors.black45;

    return GestureDetector(
      onTap: () => _openPost(item),
      child: Container(
        margin: EdgeInsets.symmetric(
          horizontal: isMobile ? 16 : 32,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: isDark ? const Color(0xFF141414) : Colors.white,
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.06),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cover image
            if (item.imageUrl.isNotEmpty || item.imageMeta != null)
              AspectRatio(
                aspectRatio: isMobile ? 16 / 9 : 21 / 9,
                child: LayoutBuilder(
                  builder: (ctx, c) => AppNetworkImage(
                    url: item.imageUrl,
                    meta: item.imageMeta,
                    width: c.maxWidth,
                    height: c.maxHeight,
                    fit: BoxFit.cover,
                    errorWidget: _buildPlaceholderCover(
                      item.title,
                      isMobile ? 200.0 : 280.0,
                    ),
                  ),
                ),
              )
            else
              _buildPlaceholderCover(
                item.title,
                isMobile ? 200.0 : 280.0,
              ),

            // Content
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Tags row
                  if (item.genres.isNotEmpty || item.writingTypes.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          ...item.writingTypes.map((t) => _buildTag(t,
                              kind: 'type')),
                          ...item.genres.map((g) => _buildTag(g,
                              kind: 'genre')),
                        ],
                      ),
                    ),

                  // Title
                  Text(
                    item.title,
                    style: GoogleFonts.inter(
                      fontSize: isMobile ? 20 : 24,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                      height: 1.2,
                      letterSpacing: -0.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),

                  // Description
                  if (item.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        item.description,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          color: textColor.withValues(alpha: 0.6),
                          height: 1.5,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),

                  // Author row + stats
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: isDark
                            ? Colors.white.withValues(alpha: 0.1)
                            : Colors.black.withValues(alpha: 0.06),
                        child: Text(
                          item.author.isNotEmpty
                              ? item.author[0].toUpperCase()
                              : '?',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: textColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.author,
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                            ),
                            Text(
                              _formatDate(item.createdAt),
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                color: textColor.withValues(alpha: 0.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),

                  // Action row
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                    ),
                    child: Consumer<AuthProvider>(
                      builder: (context, authState, _) {
                        final isLiked = authState.currentUser?.likes.contains(item.id) ?? false;
                        final saved = authState.currentUser?.savedPosts.contains(item.id) ?? false;
                        return Row(
                          children: [
                            // Like
                            _ActionButton(
                              icon: isLiked
                                  ? CupertinoIcons.heart_fill
                                  : CupertinoIcons.heart,
                              label: '${item.likesCount.clamp(0, 999999)}',
                              color: isLiked ? Colors.red : null,
                              isDark: isDark,
                              onTap: () => authState.toggleLike(item.id,
                                  feedProvider: feed),
                            ),
                            const SizedBox(width: 16),
                            // Comment
                            _ActionButton(
                              icon: CupertinoIcons.chat_bubble,
                              label: '${item.commentsCount}',
                              isDark: isDark,
                              onTap: () => _openPost(item),
                            ),
                            const SizedBox(width: 16),
                            // Sections count
                            if (item.sections.length > 1)
                              _ActionButton(
                                icon: CupertinoIcons.book,
                                label: '${item.sections.length}',
                                isDark: isDark,
                                onTap: () => _openPost(item),
                              ),
                            const Spacer(),
                            // Bookmark (save)
                            GestureDetector(
                              onTap: () => authState.toggleSave(item.id),
                              child: Icon(
                                saved
                                    ? CupertinoIcons.bookmark_fill
                                    : CupertinoIcons.bookmark,
                                size: 18,
                                color: saved
                                    ? const Color(0xFF2563EB)
                                    : subtleColor.withValues(alpha: 0.6),
                              ),
                            ),
                            const SizedBox(width: 16),
                            // More menu
                            GestureDetector(
                              onTap: () => _showMoreMenu(context, item),
                              child: Icon(
                                CupertinoIcons.ellipsis,
                                size: 18,
                                color: subtleColor.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  SliverList _buildMobileList(
    List<FeedItemModel> items,
    AuthProvider auth,
    FeedProvider feed,
  ) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _FeedCard(
              item: items[index],
              isDark: isDark,
              auth: auth,
              feed: feed,
              onTap: () => _openPost(items[index]),
              onMore: () => _showMoreMenu(context, items[index]),
            ),
          );
        },
        childCount: items.length,
      ),
    );
  }

  SliverGrid _buildDesktopGrid(
    List<FeedItemModel> items,
    AuthProvider auth,
    FeedProvider feed,
    double screenWidth,
  ) {
    final crossAxisCount = Breakpoints.isTablet(screenWidth) ? 2 : 3;
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.72,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          return _FeedCard(
            item: items[index],
            isDark: isDark,
            auth: auth,
            feed: feed,
            onTap: () => _openPost(items[index]),
            onMore: () => _showMoreMenu(context, items[index]),
          );
        },
        childCount: items.length,
      ),
    );
  }

  Widget _buildTag(String label, {String kind = 'tag'}) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    return GestureDetector(
      onTap: () => context.push(
        '/tag-feed/$kind/${Uri.encodeComponent(label)}',
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: textColor.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholderCover(String title, double height) {
    final initial = title.isNotEmpty ? title[0].toUpperCase() : '?';
    return Container(
      height: height,
      width: double.infinity,
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
          fontSize: 48,
          fontWeight: FontWeight.bold,
          color: isDark
              ? Colors.white.withValues(alpha: 0.15)
              : Colors.black.withValues(alpha: 0.1),
        ),
      ),
    );
  }

  void _openPost(FeedItemModel item) {
    context.push('/post/${item.id}', extra: item);
  }

  String _getShareUrl(String itemId) {
    return '${Uri.base.origin}/post/$itemId';
  }

  void _shareItem(FeedItemModel item) {
    Clipboard.setData(ClipboardData(text: _getShareUrl(item.id)));
    AnalyticsService.instance.track(
      'post_link_copied',
      screen: '/',
      action: 'click',
      entityType: 'post',
      entityId: item.id,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Link copied',
            style: GoogleFonts.inter(fontSize: 14),
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  void _showMoreMenu(BuildContext ctx, FeedItemModel item) {
    final isDk = isDark;
    final cardColor = isDk ? const Color(0xFF1A1A1A) : Colors.white;
    final textColor = isDk ? Colors.white : const Color(0xFF0F172A);

    showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => Container(
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetCtx).padding.bottom + 8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDk ? Colors.white24 : Colors.black12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Title
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                item.title,
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Divider(
              color: isDk ? Colors.white10 : Colors.black.withValues(alpha: 0.06),
              height: 1,
            ),
            _MoreMenuItem(
              icon: CupertinoIcons.share,
              label: 'Share',
              textColor: textColor,
              onTap: () {
                Navigator.pop(sheetCtx);
                _shareItem(item);
              },
            ),
            _MoreMenuItem(
              icon: CupertinoIcons.bookmark,
              label: 'Save to Reading List',
              textColor: textColor,
              onTap: () => Navigator.pop(sheetCtx),
            ),
            _MoreMenuItem(
              icon: CupertinoIcons.flag,
              label: 'Report',
              textColor: Colors.redAccent.withValues(alpha: 0.8),
              onTap: () => Navigator.pop(sheetCtx),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }
}

// ============================================================================
// Action button (like, comment, sections in the action row)
// ============================================================================
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final bool isDark;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.color,
    required this.isDark,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final defaultColor = isDark
        ? Colors.white.withValues(alpha: 0.45)
        : Colors.black.withValues(alpha: 0.4);
    final c = color ?? defaultColor;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17, color: c),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: c,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// More menu item
// ============================================================================
class _MoreMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color textColor;
  final VoidCallback onTap;

  const _MoreMenuItem({
    required this.icon,
    required this.label,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, size: 20, color: textColor),
      title: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: textColor,
        ),
      ),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      visualDensity: VisualDensity.compact,
    );
  }
}

// ============================================================================
// Individual feed item card with full action row
// ============================================================================
class _FeedCard extends StatelessWidget {
  final FeedItemModel item;
  final bool isDark;
  final AuthProvider auth;
  final FeedProvider feed;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const _FeedCard({
    required this.item,
    required this.isDark,
    required this.auth,
    required this.feed,
    required this.onTap,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white54 : Colors.black45;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF141414) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.06),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cover image
            AspectRatio(
              aspectRatio: 16 / 10,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  (item.imageUrl.isNotEmpty || item.imageMeta != null)
                      ? LayoutBuilder(
                          builder: (ctx, c) => AppNetworkImage(
                            url: item.imageUrl,
                            meta: item.imageMeta,
                            width: c.maxWidth,
                            height: c.maxHeight,
                            fit: BoxFit.cover,
                            errorWidget: _buildPlaceholder(item.title),
                          ),
                        )
                      : _buildPlaceholder(item.title),
                  // Section count badge
                  if (item.sections.length > 1)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(CupertinoIcons.book,
                                size: 12, color: Colors.white70),
                            const SizedBox(width: 4),
                            Text(
                              '${item.sections.length}',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Content
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Tags
                  if (item.genres.isNotEmpty || item.writingTypes.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          ...item.writingTypes
                              .take(1)
                              .map((t) =>
                                  _tag(context, t, textColor, kind: 'type')),
                          ...item.genres
                              .take(1)
                              .map((g) =>
                                  _tag(context, g, textColor, kind: 'genre')),
                        ],
                      ),
                    ),

                  // Title
                  Text(
                    item.title,
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                      height: 1.2,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),

                  // Author row
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 11,
                        backgroundColor: isDark
                            ? Colors.white.withValues(alpha: 0.1)
                            : Colors.black.withValues(alpha: 0.06),
                        child: Text(
                          item.author.isNotEmpty
                              ? item.author[0].toUpperCase()
                              : '?',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: textColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.author,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: textColor.withValues(alpha: 0.7),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Action row at bottom
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Container(
                padding: const EdgeInsets.only(top: 10),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : Colors.black.withValues(alpha: 0.06),
                    ),
                  ),
                ),
                child: Consumer<AuthProvider>(
                  builder: (context, authState, _) {
                    final isLiked = authState.currentUser?.likes.contains(item.id) ?? false;
                    final saved = authState.currentUser?.savedPosts.contains(item.id) ?? false;
                    return Row(
                      children: [
                        // Like
                        GestureDetector(
                          onTap: () =>
                              authState.toggleLike(item.id, feedProvider: feed),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isLiked
                                    ? CupertinoIcons.heart_fill
                                    : CupertinoIcons.heart,
                                size: 16,
                                color: isLiked
                                    ? Colors.red
                                    : subtleColor.withValues(alpha: 0.6),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${item.likesCount.clamp(0, 999999)}',
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: isLiked
                                      ? Colors.red
                                      : subtleColor.withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        // Comment
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(CupertinoIcons.chat_bubble,
                                size: 15,
                                color: subtleColor.withValues(alpha: 0.6)),
                            const SizedBox(width: 4),
                            Text(
                              '${item.commentsCount}',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: subtleColor.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        // Bookmark (save)
                        GestureDetector(
                          onTap: () => authState.toggleSave(item.id),
                          child: Icon(
                            saved
                                ? CupertinoIcons.bookmark_fill
                                : CupertinoIcons.bookmark,
                            size: 15,
                            color: saved
                                ? const Color(0xFF2563EB)
                                : subtleColor.withValues(alpha: 0.5)),
                        ),
                        const SizedBox(width: 12),
                        // More
                        GestureDetector(
                          onTap: onMore,
                          child: Icon(CupertinoIcons.ellipsis,
                              size: 15,
                          color: subtleColor.withValues(alpha: 0.5)),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tag(
    BuildContext context,
    String label,
    Color textColor, {
    String kind = 'tag',
  }) {
    return GestureDetector(
      onTap: () => context.push(
        '/tag-feed/$kind/${Uri.encodeComponent(label)}',
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: textColor.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder(String title) {
    final initial = title.isNotEmpty ? title[0].toUpperCase() : '?';
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
          fontSize: 36,
          fontWeight: FontWeight.bold,
          color: isDark
              ? Colors.white.withValues(alpha: 0.15)
              : Colors.black.withValues(alpha: 0.1),
        ),
      ),
    );
  }
}

// ============================================================================
// Book cover card for desktop shelves
// ============================================================================
class _BookCard extends StatefulWidget {
  final FeedItemModel item;
  final bool isDark;
  final double width;
  final bool isMobile;
  final VoidCallback onTap;

  /// When `true`, surface the recommendation's "why you'll like this"
  /// reason underneath the title. Only set on the engine-driven
  /// "Recommended for you" shelf.
  final bool showReason;

  const _BookCard({
    required this.item,
    required this.isDark,
    required this.width,
    required this.isMobile,
    required this.onTap,
    this.showReason = false,
  });

  @override
  State<_BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<_BookCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final textColor =
        widget.isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = textColor.withValues(alpha: 0.55);
    final m = widget.isMobile;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: widget.width,
          transform: Matrix4.translationValues(0, _hovering ? -4 : 0, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(m ? 10 : 12),
                  boxShadow: widget.isDark
                      ? null
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(
                                alpha: _hovering ? 0.14 : 0.08),
                            blurRadius: _hovering ? 18 : 10,
                            offset: Offset(0, _hovering ? 8 : 4),
                          ),
                        ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(m ? 10 : 12),
                  child: AspectRatio(
                    aspectRatio: 3 / 4,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        (widget.item.imageUrl.isNotEmpty ||
                                widget.item.imageMeta != null)
                            ? LayoutBuilder(
                                builder: (ctx, c) => AppNetworkImage(
                                  url: widget.item.imageUrl,
                                  meta: widget.item.imageMeta,
                                  width: c.maxWidth,
                                  height: c.maxHeight,
                                  fit: BoxFit.cover,
                                  errorWidget: _buildPlaceholder(),
                                ),
                              )
                            : _buildPlaceholder(),
                      if (_hovering)
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.35),
                              ],
                            ),
                          ),
                        ),
                      if (widget.item.sections.length > 1)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.65),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(CupertinoIcons.book,
                                    size: 10, color: Colors.white70),
                                const SizedBox(width: 3),
                                Text(
                                  '${widget.item.sections.length}',
                                  style: GoogleFonts.inter(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(height: m ? 8 : 10),
              Text(
                widget.item.title,
                style: GoogleFonts.inter(
                  fontSize: m ? 12 : 14,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                  height: 1.25,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                widget.item.author,
                style: GoogleFonts.inter(
                  fontSize: m ? 11 : 12,
                  color: subtle,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (widget.item.genres.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  widget.item.genres.first.toUpperCase(),
                  style: GoogleFonts.inter(
                    fontSize: m ? 9 : 10,
                    fontWeight: FontWeight.w600,
                    color: textColor.withValues(alpha: 0.35),
                    letterSpacing: 1.0,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (widget.showReason &&
                  (widget.item.recommendation?.reason ?? '').isNotEmpty) ...[
                SizedBox(height: m ? 4 : 6),
                Text(
                  widget.item.recommendation!.reason!,
                  style: GoogleFonts.inter(
                    fontSize: m ? 10 : 11,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF2563EB),
                    height: 1.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    final initial = widget.item.title.isNotEmpty
        ? widget.item.title[0].toUpperCase()
        : '?';
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: widget.isDark
              ? [const Color(0xFF1A1A2E), const Color(0xFF16213E)]
              : [const Color(0xFFE8EDF2), const Color(0xFFD5DCE5)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: GoogleFonts.playfairDisplay(
          fontSize: widget.isMobile ? 32 : 42,
          fontWeight: FontWeight.bold,
          color: widget.isDark
              ? Colors.white.withValues(alpha: 0.2)
              : Colors.black.withValues(alpha: 0.15),
        ),
      ),
    );
  }
}

// ============================================================================
// Ranked book card (Top 10 style — big numeral behind the cover)
// ============================================================================
class _RankedBookCard extends StatefulWidget {
  final int rank;
  final FeedItemModel item;
  final bool isDark;
  final double width;
  final double numeralWidth;
  final bool isMobile;
  final VoidCallback onTap;

  const _RankedBookCard({
    required this.rank,
    required this.item,
    required this.isDark,
    required this.width,
    required this.numeralWidth,
    required this.isMobile,
    required this.onTap,
  });

  @override
  State<_RankedBookCard> createState() => _RankedBookCardState();
}

class _RankedBookCardState extends State<_RankedBookCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final textColor =
        widget.isDark ? Colors.white : const Color(0xFF0F172A);
    final m = widget.isMobile;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: widget.width,
          transform: Matrix4.translationValues(0, _hovering ? -4 : 0, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SizedBox(
                    width: widget.numeralWidth,
                    child: Text(
                      '${widget.rank}',
                      style: GoogleFonts.playfairDisplay(
                        fontSize: m ? 110 : 160,
                        fontWeight: FontWeight.w900,
                        height: 0.85,
                        color: widget.isDark
                            ? Colors.white.withValues(alpha: 0.35)
                            : Colors.black.withValues(alpha: 0.25),
                        letterSpacing: m ? -5 : -8,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(m ? 8 : 10),
                      child: AspectRatio(
                        aspectRatio: 3 / 4,
                        child: (widget.item.imageUrl.isNotEmpty ||
                                widget.item.imageMeta != null)
                            ? LayoutBuilder(
                                builder: (ctx, c) => AppNetworkImage(
                                  url: widget.item.imageUrl,
                                  meta: widget.item.imageMeta,
                                  width: c.maxWidth,
                                  height: c.maxHeight,
                                  fit: BoxFit.cover,
                                  errorWidget: _buildPlaceholder(),
                                ),
                              )
                            : _buildPlaceholder(),
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: m ? 8 : 10),
              Padding(
                padding: EdgeInsets.only(left: widget.numeralWidth),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.item.title,
                      style: GoogleFonts.inter(
                        fontSize: m ? 13 : 15,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                        height: 1.25,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: m ? 2 : 3),
                    Text(
                      widget.item.author,
                      style: GoogleFonts.inter(
                        fontSize: m ? 11 : 12,
                        fontWeight: FontWeight.w500,
                        color: textColor.withValues(alpha: 0.7),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    final initial = widget.item.title.isNotEmpty
        ? widget.item.title[0].toUpperCase()
        : '?';
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: widget.isDark
              ? [const Color(0xFF1A1A2E), const Color(0xFF16213E)]
              : [const Color(0xFFE8EDF2), const Color(0xFFD5DCE5)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: GoogleFonts.playfairDisplay(
          fontSize: widget.isMobile ? 28 : 36,
          fontWeight: FontWeight.bold,
          color: widget.isDark
              ? Colors.white.withValues(alpha: 0.2)
              : Colors.black.withValues(alpha: 0.15),
        ),
      ),
    );
  }
}

// ============================================================================
// "X new posts" pill — Twitter / Instagram style. Slides in from the top
// when silent-refresh discovers items the user hasn't seen, sits above the
// scroll view without blocking it, and on tap inserts the buffered items
// + animates a scroll-to-top so the user lands on what they came for.
// ============================================================================
class _NewPostsPill extends StatelessWidget {
  const _NewPostsPill({
    required this.count,
    required this.isDark,
    required this.onTap,
  });

  final int count;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final visible = count > 0;
    final bg = isDark ? Colors.white : const Color(0xFF0F172A);
    final fg = isDark ? const Color(0xFF0F172A) : Colors.white;
    final label = count == 1 ? '1 new post' : '$count new posts';
    final topPadding = MediaQuery.paddingOf(context).top;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        offset: visible ? Offset.zero : const Offset(0, -1.4),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: visible ? 1 : 0,
          child: Padding(
            padding: EdgeInsets.only(top: topPadding + 12),
            child: Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.arrow_upward_rounded, size: 16, color: fg),
                        const SizedBox(width: 6),
                        Text(
                          label,
                          style: GoogleFonts.inter(
                            color: fg,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Empty-state hero — replaces the old "Your feed is empty" stub. Surfaces
// the two real next steps (refresh / customize) plus a write CTA.
// ============================================================================
class _FeedEmptyState extends StatelessWidget {
  const _FeedEmptyState({
    required this.isDark,
    required this.error,
    required this.onRefresh,
    required this.onCustomize,
    required this.onWrite,
  });

  final bool isDark;
  final String? error;
  final Future<void> Function() onRefresh;
  final VoidCallback onCustomize;
  final VoidCallback onWrite;

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final muted = textColor.withValues(alpha: 0.55);
    final accent = const Color(0xFF2563EB);

    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isDark
                          ? [const Color(0xFF1E2535), const Color(0xFF0F172A)]
                          : [const Color(0xFFEFF4FB), const Color(0xFFE0E8F4)],
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.12),
                        blurRadius: 24,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    CupertinoIcons.book_circle_fill,
                    size: 44,
                    color: accent.withValues(alpha: 0.85),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  'A quiet shelf — for now',
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                    letterSpacing: -0.4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  'Once writers around you publish, their stories will land here. '
                  'Tune your feed to bring more of what you love into view.',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: muted,
                    height: 1.55,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (error != null) ...[
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.red.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Text(
                      error!.length > 140
                          ? '${error!.substring(0, 140)}…'
                          : error!,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Colors.redAccent.withValues(alpha: 0.85),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                Row(
                  children: [
                    Expanded(
                      child: _PrimaryAction(
                        label: 'Refresh',
                        icon: CupertinoIcons.arrow_clockwise,
                        isDark: isDark,
                        onTap: onRefresh,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _SecondaryAction(
                        label: 'Tune feed',
                        icon: CupertinoIcons.slider_horizontal_3,
                        isDark: isDark,
                        onTap: onCustomize,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                _GhostLink(
                  label: 'or start writing your own story',
                  icon: CupertinoIcons.pencil,
                  isDark: isDark,
                  onTap: onWrite,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.label,
    required this.icon,
    required this.isDark,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isDark;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(vertical: 14),
      color: isDark ? Colors.white : Colors.black,
      borderRadius: BorderRadius.circular(12),
      onPressed: () => onTap(),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: isDark ? Colors.black : Colors.white),
          const SizedBox(width: 8),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.black : Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _SecondaryAction extends StatelessWidget {
  const _SecondaryAction({
    required this.label,
    required this.icon,
    required this.isDark,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = isDark ? Colors.white : const Color(0xFF0F172A);
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(vertical: 14),
      color: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(12),
      onPressed: onTap,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 8),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

class _GhostLink extends StatefulWidget {
  const _GhostLink({
    required this.label,
    required this.icon,
    required this.isDark,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isDark;
  final VoidCallback onTap;

  @override
  State<_GhostLink> createState() => _GhostLinkState();
}

class _GhostLinkState extends State<_GhostLink> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.isDark
        ? Colors.white.withValues(alpha: 0.55)
        : Colors.black.withValues(alpha: 0.55);
    final hover = widget.isDark ? Colors.white : Colors.black;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 160),
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: _hovering ? hover : base,
            decoration: TextDecoration.none,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 13, color: _hovering ? hover : base),
              const SizedBox(width: 6),
              Text(widget.label),
            ],
          ),
        ),
      ),
    );
  }
}
