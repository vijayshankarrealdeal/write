import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:writer/ui/utilities/responsive_layout.dart';

class Feed extends StatefulWidget {
  const Feed({super.key});

  @override
  State<Feed> createState() => _FeedState();
}

class _FeedState extends State<Feed> {
  // Helper to check if dark mode is currently active
  bool get isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = Breakpoints.isMobile(width);
    final isTablet = Breakpoints.isTablet(width);

    // Premium adaptive colors
    final textColor = isDark ? Colors.white : Colors.black;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);

    final horizontalPadding = isMobile ? 16.0 : (isTablet ? 24.0 : 32.0);
    final topPadding = isMobile ? 16.0 : 32.0;

    return Scaffold(
      backgroundColor: bgColor,
      body: CustomScrollView(
        slivers: [
          // 1. TOP ACTION ROW
          SliverPadding(
            padding: EdgeInsets.fromLTRB(horizontalPadding, topPadding, horizontalPadding, 24.0),
            sliver: SliverToBoxAdapter(
              child: _buildActionRow(textColor, isMobile),
            ),
          ),

          // 2. MAIN CONTENT AREA
          SliverPadding(
            padding: EdgeInsets.fromLTRB(horizontalPadding, 0, horizontalPadding, 48.0),
            sliver: SliverToBoxAdapter(
              child: isMobile
                  ? _buildMobileLayout(textColor)
                  : _buildDesktopLayout(textColor, isTablet),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout(Color textColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTrendingSection(isMobile: true),
        const SizedBox(height: 20),
        SizedBox(height: 200, child: _buildBottomGallery()),
        const SizedBox(height: 24),
        _buildSidebar(textColor, isMobile: true),
      ],
    );
  }

  Widget _buildDesktopLayout(Color textColor, bool isTablet) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: isTablet ? 3 : 28,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTrendingSection(isMobile: false),
                const SizedBox(height: 20),
                SizedBox(height: isTablet ? 280 : 340, child: _buildBottomGallery()),
              ],
            ),
          ),
          SizedBox(width: isTablet ? 16 : 24),
          Expanded(flex: isTablet ? 1 : 10, child: _buildSidebar(textColor, isMobile: false)),
        ],
      ),
    );
  }

  // ===========================================================================
  // 1. TOP NAVIGATION ROW
  // ===========================================================================
  Widget _buildActionRow(Color textColor, bool isMobile) {
    // Soft, noiseless backgrounds for UI elements
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
                child: _buildPillButton("Continue Reading", boxColor, textColor),
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
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: boxColor,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Row(
              children: [
                Icon(CupertinoIcons.search, color: hintColor, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    style: TextStyle(color: textColor, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: "Search",
                      hintStyle: GoogleFonts.inter(
                        color: hintColor,
                        fontSize: 15,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ],
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

  // ===========================================================================
  // 2. TRENDING SECTION (Left Column Top)
  // ===========================================================================
  Widget _buildTrendingSection({required bool isMobile}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Dark Header
          Container(
            color: const Color(0xFF0A0A0A),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Text(
              "Trending Articles",
              style: GoogleFonts.inter(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ),
          // Yellow Body
          Container(
            color: const Color(0xFFFFCC00),
            padding: EdgeInsets.all(isMobile ? 16 : 20),
            child: isMobile
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildArticleCard(
                        title: "Paper Faces,\nReal Skin:\nOn the Mask\nWe Choose",
                        author: "Nina Abraham",
                        description:
                            "You are not your reflection. You are not your bio. You're not even your favourite book.",
                        imageUrl:
                            "https://images.unsplash.com/photo-1544502062-f82887f03d1c?fit=crop&w=400&q=80",
                        isMobile: true,
                      ),
                      const SizedBox(height: 16),
                      _buildArticleCard(
                        title: "Soft\nApocalypse:\nHow We Fall\nApart Quietly",
                        author: "Rayan V",
                        description:
                            "Some days, your thoughts feel like bubblegum caught in a microwave.",
                        imageUrl:
                            "https://images.unsplash.com/photo-1618005182384-a83a8bd57fbe?fit=crop&w=400&q=80",
                        isMobile: true,
                      ),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _buildArticleCard(
                          title: "Paper Faces,\nReal Skin:\nOn the Mask\nWe Choose",
                          author: "Nina Abraham",
                          description:
                              "You are not your reflection. You are not your bio. You're not even your favourite book. This essay explores the absurdity of identity in a world where we curate ourselves more than we understand ourselves.",
                          imageUrl:
                              "https://images.unsplash.com/photo-1544502062-f82887f03d1c?fit=crop&w=400&q=80",
                          isMobile: false,
                        ),
                      ),
                      const SizedBox(width: 32),
                      Expanded(
                        child: _buildArticleCard(
                          title: "Soft\nApocalypse:\nHow We Fall\nApart Quietly",
                          author: "Rayan V",
                          description:
                              "Some days, your thoughts feel like bubblegum caught in a microwave. This isn't a piece about breakdowns—it's about breakthroughs that look like breakdowns.",
                          imageUrl:
                              "https://images.unsplash.com/photo-1618005182384-a83a8bd57fbe?fit=crop&w=400&q=80",
                          isMobile: false,
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
    required String title,
    required String author,
    required String description,
    required String imageUrl,
    bool isMobile = false,
  }) {
    final imageSize = isMobile ? 100.0 : 130.0;
    final imageHeight = isMobile ? 120.0 : 160.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(
            imageUrl,
            width: imageSize,
            height: imageHeight,
            fit: BoxFit.cover,
          ),
        ),
        SizedBox(width: isMobile ? 12 : 20),
        // Text Content
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
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
                author,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.black.withOpacity(0.8),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                description,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  height: 1.5,
                  color: Colors.black.withOpacity(0.7),
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // 3. BOTTOM GALLERY (Left Column Bottom)
  // ===========================================================================
  Widget _buildBottomGallery() {
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = Breakpoints.isMobile(width);

    final images = [
      "https://images.unsplash.com/photo-1533738363-b7f9aef128ce?fit=crop&w=400&q=80",
      "https://images.unsplash.com/photo-1507608616759-54f48f0af0ee?fit=crop&w=400&q=80",
      "https://images.unsplash.com/photo-1604076913837-52ab5629fba9?fit=crop&w=400&q=80",
      "https://images.unsplash.com/photo-1550684848-fac1c5b4e853?fit=crop&w=400&q=80",
    ];

    if (isMobile) {
      return ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: images.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          return SizedBox(
            width: 140,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(images[index], fit: BoxFit.cover),
            ),
          );
        },
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: images.map((url) {
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: url == images.last ? 0 : 20.0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(url, fit: BoxFit.cover),
            ),
          ),
        );
      }).toList(),
    );
  }

  // ===========================================================================
  // 4. RIGHT SIDEBAR (Premium, Robust, Noiseless)
  // ===========================================================================
  Widget _buildSidebar(Color textColor, {required bool isMobile}) {
    // Subtle colors reduce visual noise
    final cardColor = isDark
        ? Colors.white.withOpacity(0.04)
        : Colors.black.withOpacity(0.02);
    // A very faint border creates a crisp edge without being distracting
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
                        color: isDark
                            ? const Color(0xFF1E1E20)
                            : Colors.white,
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
            onTap: () {
              // Action triggers smoothly
            },
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
