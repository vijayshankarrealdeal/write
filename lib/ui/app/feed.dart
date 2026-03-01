import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:writer/models/feed_item_model.dart';
import 'package:writer/models/user_preferences_model.dart';
import 'package:writer/provider/auth_provider.dart';
import 'package:writer/provider/feed_provider.dart';
import 'package:writer/ui/utilities/responsive_layout.dart';

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
    feed.ensureSeedData().then((_) async {
      if (feed.items.isNotEmpty) {
        feed.silentRefresh(); // Tab revisited: append new items silently
      } else {
        await feed.loadFeedIfNeeded(prefs);
      }
    });
  }

  Future<void> _onRefresh() async {
    final auth = context.read<AuthProvider>();
    final feed = context.read<FeedProvider>();
    final prefs = auth.currentUser?.preferences ?? const UserPreferences();
    await feed.loadFeed(prefs, forceRefresh: true);
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

        return Scaffold(
          backgroundColor: bgColor,
          body: RefreshIndicator(
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
                        : _buildDesktopLayout(textColor, isTablet, feed, auth),
                  ),
                ),
              ],
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
    final user = auth.currentUser;

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
        if (user != null) ...[
          const SizedBox(width: 16),
          CircleAvatar(
            radius: 18,
            backgroundColor: isDark ? Colors.white12 : Colors.black12,
            backgroundImage: user.photoUrl != null
                ? NetworkImage(user.photoUrl!)
                : null,
            child: user.photoUrl == null
                ? Icon(CupertinoIcons.person, size: 18, color: textColor)
                : null,
          ),
        ],
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

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: CachedNetworkImage(
            imageUrl: item.imageUrl,
            width: imageSize,
            height: imageHeight,
            fit: BoxFit.cover,
            placeholder: (_, __) => Container(
              color: Colors.grey[300],
              child: const Center(child: CupertinoActivityIndicator()),
            ),
            errorWidget: (_, __, ___) => Container(
              color: Colors.grey[300],
              child: Icon(CupertinoIcons.photo, size: 40),
            ),
          ),
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
              const SizedBox(height: 12),
              Text(
                item.author,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.black.withOpacity(0.8),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                item.description,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  height: 1.5,
                  color: Colors.black.withOpacity(0.7),
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    icon: Icon(
                      liked ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
                      color: liked ? Colors.red : Colors.black54,
                      size: 20,
                    ),
                    onPressed: () async {
                      await auth.toggleLike(item.id);
                      if (mounted) _loadFeed();
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    "${item.likesCount}",
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
    );
  }

  Widget _buildBottomGallery(List<FeedItemModel> items) {
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = Breakpoints.isMobile(width);

    final fallbackUrls = [
      "https://images.unsplash.com/photo-1533738363-b7f9aef128ce?fit=crop&w=400&q=80",
      "https://images.unsplash.com/photo-1507608616759-54f48f0af0ee?fit=crop&w=400&q=80",
      "https://images.unsplash.com/photo-1604076913837-52ab5629fba9?fit=crop&w=400&q=80",
      "https://images.unsplash.com/photo-1550684848-fac1c5b4e853?fit=crop&w=400&q=80",
    ];
    final urls = items.isNotEmpty
        ? items.take(4).map((e) => e.imageUrl).toList()
        : fallbackUrls;
    while (urls.length < 4) urls.add(fallbackUrls[urls.length % 4]);

    if (isMobile) {
      return ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: urls.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          return SizedBox(
            width: 140,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: CachedNetworkImage(
                imageUrl: urls[index],
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                  color: Colors.grey[300],
                  child: const Center(child: CupertinoActivityIndicator()),
                ),
                errorWidget: (_, __, ___) => Container(
                  color: Colors.grey[300],
                  child: Icon(CupertinoIcons.photo),
                ),
              ),
            ),
          );
        },
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: urls.map((url) {
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: url == urls.last ? 0 : 20.0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                  color: Colors.grey[300],
                  child: const Center(child: CupertinoActivityIndicator()),
                ),
                errorWidget: (_, __, ___) => Container(
                  color: Colors.grey[300],
                  child: Icon(CupertinoIcons.photo),
                ),
              ),
            ),
          ),
        );
      }).toList(),
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
