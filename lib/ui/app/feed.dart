import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/ui/pages/post_detail_page.dart';
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

  void _loadFeed() {
    final auth = context.read<AuthProvider>();
    final feed = context.read<FeedProvider>();
    final prefs = auth.currentUser?.preferences ?? const UserPreferences();
    final userId = auth.currentUser?.id;
    if (feed.items.isNotEmpty) {
      feed.silentRefresh();
    } else {
      feed.loadFeedIfNeeded(prefs, userId: userId);
    }
    if (userId != null) {
      feed.loadReadingProgress(userId);
    }
  }

  Future<void> _onRefresh() async {
    final auth = context.read<AuthProvider>();
    final feed = context.read<FeedProvider>();
    final prefs = auth.currentUser?.preferences ?? const UserPreferences();
    await feed.loadFeed(prefs, forceRefresh: true, userId: auth.currentUser?.id);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = Breakpoints.isMobile(width);
    final isTablet = Breakpoints.isTablet(width);
    final textColor = isDark ? Colors.white : Colors.black;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final horizontalPadding = isMobile ? 16.0 : (isTablet ? 24.0 : 32.0);
    final topPadding = isMobile ? 16.0 : 32.0;

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
                    style: GoogleFonts.inter(color: textColor.withOpacity(0.6)),
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
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    CupertinoIcons.book,
                    size: 64,
                    color: textColor.withOpacity(0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    "No posts yet",
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Follow writers or explore categories to see posts here",
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      color: textColor.withOpacity(0.5),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
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
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      topPadding,
                      horizontalPadding,
                      24.0,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: _buildActionRow(textColor, isMobile, auth),
                    ),
                  ),
                  if (feed.getContinueReadingItems().isNotEmpty)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        0,
                        horizontalPadding,
                        16.0,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: _buildContinueReadingSection(
                          textColor,
                          feed.getContinueReadingItems(),
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      0,
                      horizontalPadding,
                      48.0,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: isMobile
                          ? _buildMobileLayout(textColor, feed, auth)
                          : _buildDesktopLayout(
                              textColor, isTablet, feed, auth),
                    ),
                  ),
                  if (feed.isLoadingMore)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: 32),
                        child: Center(child: CupertinoActivityIndicator()),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMobileLayout(
    Color textColor,
    FeedProvider feed,
    AuthProvider auth,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTrendingSection(
          feed.items.take(2).toList(),
          isMobile: true,
          auth: auth,
        ),
        const SizedBox(height: 20),
        SizedBox(
          height: 200,
          child: _buildBottomGallery(
            feed.items.length > 2 ? feed.items.sublist(2) : [],
          ),
        ),
        const SizedBox(height: 24),
        _buildSidebar(textColor, isMobile: true),
      ],
    );
  }

  Widget _buildDesktopLayout(
    Color textColor,
    bool isTablet,
    FeedProvider feed,
    AuthProvider auth,
  ) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: isTablet ? 3 : 28,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTrendingSection(
                  feed.items.take(2).toList(),
                  isMobile: false,
                  auth: auth,
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: isTablet ? 280 : 340,
                  child: _buildBottomGallery(
                    feed.items.length > 2 ? feed.items.sublist(2) : [],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: isTablet ? 16 : 24),
          Expanded(
            flex: isTablet ? 1 : 10,
            child: _buildSidebar(textColor, isMobile: false),
          ),
        ],
      ),
    );
  }

  Widget _buildActionRow(Color textColor, bool isMobile, AuthProvider auth) {
    final boxColor = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.black.withOpacity(0.04);
    final hintColor = isDark ? Colors.white54 : Colors.black54;

    if (isMobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: boxColor,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Row(
              children: [
                Icon(CupertinoIcons.search, color: hintColor, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    style: TextStyle(color: textColor, fontSize: 17),
                    decoration: InputDecoration(
                      hintText: "Search",
                      hintStyle: GoogleFonts.inter(
                        color: hintColor,
                        fontSize: 17,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildPillButton(
                  "Continue Reading",
                  boxColor,
                  textColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildPillButton("Reading List", boxColor, textColor),
              ),
            ],
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          flex: 4,
          child: TextField(
            style: TextStyle(color: textColor, fontSize: 15),
            decoration: InputDecoration(
              hintText: "Search",
              hintStyle: GoogleFonts.inter(color: hintColor, fontSize: 15),
              border: InputBorder.none,
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 2,
          child: _buildPillButton("Continue Reading", boxColor, textColor),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 2,
          child: _buildPillButton("Your Reading List", boxColor, textColor),
        ),
      ],
    );
  }

  Widget _buildPillButton(String text, Color bgColor, Color textColor) {
    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () {},
        child: Container(
          height: 52,
          alignment: Alignment.center,
          child: Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 15,
              color: textColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContinueReadingSection(
    Color textColor,
    List<FeedItemModel> items,
  ) {
    final cardColor = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.black.withOpacity(0.04);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Continue Reading",
          style: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 72,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = items[index];
              return GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    CupertinoPageRoute(
                      builder: (_) => PostDetailPage(item: item),
                    ),
                  );
                },
                child: Container(
                  width: 220,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        item.title,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Continue",
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: isDark
                              ? const Color(0xFFFFCC00)
                              : const Color(0xFF1982C4),
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
    );
  }

  Widget _buildTrendingSection(
    List<FeedItemModel> items, {
    required bool isMobile,
    required AuthProvider auth,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            color: const Color(0xFF0A0A0A),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                Text(
                  "For You",
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  "• Based on your preferences",
                  style: GoogleFonts.inter(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            color: const Color(0xFFFFCC00),
            padding: EdgeInsets.all(isMobile ? 16 : 20),
            child: items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      "Select genres in onboarding to personalize your feed.",
                      style: GoogleFonts.inter(
                        color: Colors.black87,
                        fontSize: 14,
                      ),
                    ),
                  )
                : isMobile
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final item in items)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _buildArticleCard(
                            item: item,
                            isMobile: true,
                            auth: auth,
                          ),
                        ),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final item in items)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: item != items.last ? 32 : 0,
                            ),
                            child: _buildArticleCard(
                              item: item,
                              isMobile: false,
                              auth: auth,
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildArticleCard({
    required FeedItemModel item,
    required bool isMobile,
    required AuthProvider auth,
  }) {
    final imageSize = isMobile ? 100.0 : 130.0;
    final imageHeight = isMobile ? 120.0 : 160.0;
    final liked = auth.currentUser?.likes.contains(item.id) ?? false;

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          CupertinoPageRoute(builder: (_) => PostDetailPage(item: item)),
        );
      },
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: item.imageUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: item.imageUrl,
                    width: imageSize,
                    height: imageHeight,
                    fit: BoxFit.cover,
                    placeholder: (_, url) => Container(
                      width: imageSize,
                      height: imageHeight,
                      color: Colors.grey[300],
                      child: const Center(child: CupertinoActivityIndicator()),
                    ),
                    errorWidget: (_, url, error) => _buildPlaceholderImage(
                      imageSize,
                      imageHeight,
                      item.title,
                    ),
                  )
                : _buildPlaceholderImage(imageSize, imageHeight, item.title),
          ),
          SizedBox(width: isMobile ? 12 : 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: GoogleFonts.playfairDisplay(
                    color: Colors.black,
                    fontSize: isMobile ? 18 : 24,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 8),
                if (item.bookTitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      "From: ${item.bookTitle}",
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: Colors.black45,
                      ),
                    ),
                  ),
                Text(
                  item.author,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.black.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  item.description,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    height: 1.5,
                    color: Colors.black.withValues(alpha: 0.7),
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    GestureDetector(
                      onTap: () async {
                        await auth.toggleLike(item.id);
                        if (mounted) _loadFeed();
                      },
                      child: Icon(
                        liked
                            ? CupertinoIcons.heart_fill
                            : CupertinoIcons.heart,
                        color: liked ? Colors.red : Colors.black54,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      "${item.likesCount}",
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Icon(
                      CupertinoIcons.chat_bubble,
                      color: Colors.black54,
                      size: 16,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      "${item.commentsCount}",
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholderImage(double w, double h, String title) {
    final initial = title.isNotEmpty ? title[0].toUpperCase() : '?';
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: GoogleFonts.playfairDisplay(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: Colors.grey[500],
        ),
      ),
    );
  }

  Widget _buildBottomGallery(List<FeedItemModel> items) {
    if (items.isEmpty) return const SizedBox.shrink();

    final width = MediaQuery.sizeOf(context).width;
    final isMobile = Breakpoints.isMobile(width);
    final displayItems = items.take(4).toList();

    if (isMobile) {
      return ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: displayItems.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final item = displayItems[index];
          return SizedBox(
            width: 140,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: item.imageUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: item.imageUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        color: Colors.grey[300],
                        child: const Center(child: CupertinoActivityIndicator()),
                      ),
                      errorWidget: (_, __, ___) => _buildGalleryPlaceholder(item.title),
                    )
                  : _buildGalleryPlaceholder(item.title),
            ),
          );
        },
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < displayItems.length; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == displayItems.length - 1 ? 0 : 20.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: displayItems[i].imageUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: displayItems[i].imageUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(
                          color: Colors.grey[300],
                          child: const Center(child: CupertinoActivityIndicator()),
                        ),
                        errorWidget: (_, __, ___) =>
                            _buildGalleryPlaceholder(displayItems[i].title),
                      )
                    : _buildGalleryPlaceholder(displayItems[i].title),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildGalleryPlaceholder(String title) {
    final initial = title.isNotEmpty ? title[0].toUpperCase() : '?';
    return Container(
      color: Colors.grey[200],
      alignment: Alignment.center,
      child: Text(
        initial,
        style: GoogleFonts.playfairDisplay(
          fontSize: 28,
          fontWeight: FontWeight.bold,
          color: Colors.grey[500],
        ),
      ),
    );
  }

  Widget _buildSidebar(Color textColor, {required bool isMobile}) {
    final cardColor = isDark
        ? Colors.white.withOpacity(0.04)
        : Colors.black.withOpacity(0.02);
    final borderColor = isDark
        ? Colors.white.withOpacity(0.05)
        : Colors.black.withOpacity(0.05);

    final dropZone = Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Padding(
        padding: EdgeInsets.all(isMobile ? 20 : 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 64,
              height: 64,
              child: Stack(
                children: [
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Icon(
                      CupertinoIcons.square_on_square,
                      size: 42,
                      color: textColor.withOpacity(0.4),
                    ),
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E1E20) : Colors.white,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        CupertinoIcons.cursor_rays,
                        size: 28,
                        color: textColor.withOpacity(0.9),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Text(
              "Drag any article into\nyour reading list",
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 15,
                height: 1.4,
                color: textColor.withOpacity(0.8),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );

    return Column(
      mainAxisSize: isMobile ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (isMobile) dropZone else Expanded(child: dropZone),
        SizedBox(height: isMobile ? 16 : 20),
        Material(
          color: cardColor,
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () {},
            child: Container(
              height: 52,
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: borderColor, width: 1),
              ),
              alignment: Alignment.center,
              child: Text(
                "Join live club Discussion",
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: textColor.withOpacity(0.9),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
