import 'package:cached_network_image/cached_network_image.dart';
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
import 'package:inkspacex/ui/utilities/responsive_layout.dart';

class Feed extends StatefulWidget {
  const Feed({super.key});

  @override
  State<Feed> createState() => _FeedState();
}

class _FeedState extends State<Feed> {
  bool get isDark => Theme.of(context).brightness == Brightness.dark;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFeed());
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

    } catch (e) {
      debugPrint("Error loading feed: $e");
    }
  }

  Future<void> _onRefresh() async {
    final auth = context.read<AuthProvider>();
    final feed = context.read<FeedProvider>();
    final prefs = auth.currentUser?.preferences ?? const UserPreferences();
    await feed.loadFeed(
      prefs,
      forceRefresh: true,
      userId: auth.currentUser?.id,
    );
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
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CupertinoActivityIndicator(color: textColor),
                  const SizedBox(height: 16),
                  Text(
                    "Loading your feed...",
                    style: GoogleFonts.inter(
                      color: textColor.withValues(alpha: 0.5),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        if (feed.items.isEmpty && !feed.isLoading) {
          return Scaffold(
            backgroundColor: bgColor,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : Colors.black.withValues(alpha: 0.04),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                              CupertinoIcons.book,
                              size: 48,
                              color: textColor.withValues(alpha: 0.3),
                            ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      "Your feed is empty",
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Published stories from the community will appear here",
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: textColor.withValues(alpha: 0.5),
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),

                    // Show error if any
                    if (feed.error != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          feed.error!.length > 120
                              ? '${feed.error!.substring(0, 120)}...'
                              : feed.error!,
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: Colors.redAccent.withValues(alpha: 0.7),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),
                    CupertinoButton(
                      color: isDark ? Colors.white : Colors.black,
                      borderRadius: BorderRadius.circular(12),
                      onPressed: _onRefresh,
                      child: Text(
                        "Refresh",
                        style: GoogleFonts.inter(
                          color: isDark ? Colors.black : Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return Scaffold(
          backgroundColor: bgColor,
          body: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.pixels >=
                  notification.metrics.maxScrollExtent - 200) {
                feed.loadMore(userId: auth.currentUser?.id);
              }
              return false;
            },
            child: RefreshIndicator(
              onRefresh: _onRefresh,
              color: textColor,
              child: _buildShelfHome(feed, auth, textColor, width, isMobile),
            ),
          ),
        );
      },
    );
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
      return const Center(child: CupertinoActivityIndicator());
    }

    final continueReading = feed.getContinueReadingItems();
    final userGenres = auth.currentUser?.preferences.preferredGenres
            .map((g) => g.toLowerCase())
            .toSet() ??
        <String>{};

    final recommended = userGenres.isEmpty
        ? all.take(12).toList()
        : all
            .where((i) =>
                i.genres.any((g) => userGenres.contains(g.toLowerCase())))
            .take(12)
            .toList();

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
              title: userGenres.isEmpty
                  ? 'Featured picks'
                  : 'Recommended for you',
              subtitle: userGenres.isEmpty
                  ? null
                  : 'Based on your reading preferences',
              items: recommended,
              textColor: textColor,
              hPadding: hPadding,
              cardWidth: cardWidth,
              shelfHeight: shelfHeight,
              isMobile: isMobile,
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
              child: Center(child: CupertinoActivityIndicator()),
            ),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
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

    final cover = AspectRatio(
      aspectRatio: isMobile ? 16 / 10 : 4 / 5,
      child: item.imageUrl.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: item.imageUrl,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                color: isDark ? Colors.white10 : Colors.grey[200],
              ),
              errorWidget: (_, __, ___) =>
                  _buildPlaceholderCover(item.title, isMobile ? 180 : 380),
            )
          : _buildPlaceholderCover(item.title, isMobile ? 180 : 380),
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
              itemBuilder: (context, index) => _BookCard(
                item: items[index],
                isDark: isDark,
                width: cardWidth,
                isMobile: isMobile,
                onTap: () => _openPost(items[index]),
              ),
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
            if (item.imageUrl.isNotEmpty)
              AspectRatio(
                aspectRatio: isMobile ? 16 / 9 : 21 / 9,
                child: CachedNetworkImage(
                  imageUrl: item.imageUrl,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    color: isDark ? Colors.white10 : Colors.grey[200],
                    child: const Center(child: CupertinoActivityIndicator()),
                  ),
                  errorWidget: (_, __, ___) => _buildPlaceholderCover(
                    item.title,
                    isMobile ? 200.0 : 280.0,
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
                          ...item.writingTypes.map((t) => _buildTag(t)),
                          ...item.genres.map((g) => _buildTag(g)),
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

  Widget _buildTag(String label) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    return Container(
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
                  item.imageUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: item.imageUrl,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(
                            color: isDark ? Colors.white10 : Colors.grey[200],
                            child: const Center(
                              child: CupertinoActivityIndicator(),
                            ),
                          ),
                          errorWidget: (_, __, ___) =>
                              _buildPlaceholder(item.title),
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
                              .map((t) => _tag(t, textColor)),
                          ...item.genres
                              .take(1)
                              .map((g) => _tag(g, textColor)),
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

  Widget _tag(String label, Color textColor) {
    return Container(
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

  const _BookCard({
    required this.item,
    required this.isDark,
    required this.width,
    required this.isMobile,
    required this.onTap,
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
              ClipRRect(
                borderRadius: BorderRadius.circular(m ? 10 : 12),
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      widget.item.imageUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: widget.item.imageUrl,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => Container(
                                color: widget.isDark
                                    ? Colors.white10
                                    : Colors.grey[200],
                              ),
                              errorWidget: (_, __, ___) =>
                                  _buildPlaceholder(),
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
                        child: widget.item.imageUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: widget.item.imageUrl,
                                fit: BoxFit.cover,
                                placeholder: (_, __) => Container(
                                  color: widget.isDark
                                      ? Colors.white10
                                      : Colors.grey[200],
                                ),
                                errorWidget: (_, __, ___) =>
                                    _buildPlaceholder(),
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
