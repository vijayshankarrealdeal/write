import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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
    // Premium adaptive colors
    final textColor = isDark ? Colors.white : Colors.black;
    final bgColor = isDark ? const Color(0xFF0E0E10) : const Color(0xFFF5F5F7);

    return Scaffold(
      backgroundColor: bgColor, // Deep, premium background color
      body: CustomScrollView(
        slivers: [
          // 1. TOP ACTION ROW
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(32.0, 32.0, 32.0, 24.0),
            sliver: SliverToBoxAdapter(child: _buildActionRow(textColor)),
          ),

          // 2. MAIN CONTENT AREA
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(32.0, 0, 32.0, 48.0),
            sliver: SliverToBoxAdapter(
              // IntrinsicHeight forces the right sidebar to stretch exactly
              // as tall as the left content column, creating a perfect grid.
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // LEFT COLUMN (Trending & Gallery)
                    Expanded(
                      flex: 28,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildTrendingSection(),
                          const SizedBox(height: 20),
                          // Fixed height for the gallery since it's in a ScrollView
                          SizedBox(height: 340, child: _buildBottomGallery()),
                        ],
                      ),
                    ),

                    const SizedBox(width: 24),

                    // RIGHT COLUMN (Sidebar)
                    Expanded(flex: 10, child: _buildSidebar(textColor)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 1. TOP NAVIGATION ROW
  // ===========================================================================
  Widget _buildActionRow(Color textColor) {
    // Soft, noiseless backgrounds for UI elements
    final boxColor = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.black.withOpacity(0.04);
    final hintColor = isDark ? Colors.white54 : Colors.black54;

    return Row(
      children: [
        // Search Bar
        Expanded(
          flex: 4,
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: boxColor,
              borderRadius: BorderRadius.circular(24),
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

        // Continue Reading Button
        Expanded(
          flex: 2,
          child: _buildPillButton("Continue Reading", boxColor, textColor),
        ),
        const SizedBox(width: 16),

        // Your Reading List Button
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
        onTap: () {}, // Robust: reacts to taps
        child: Container(
          height: 48,
          alignment: Alignment.center,
          child: Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 14,
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
  Widget _buildTrendingSection() {
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
            padding: const EdgeInsets.all(20),
            child: Row(
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
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Image
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(
            imageUrl,
            width: 130,
            height: 160,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 20),
        // Text Content
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.playfairDisplay(
                  color: Colors
                      .black, // Explicitly black for the yellow background
                  fontSize: 24,
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
    final images = [
      "https://images.unsplash.com/photo-1533738363-b7f9aef128ce?fit=crop&w=400&q=80",
      "https://images.unsplash.com/photo-1507608616759-54f48f0af0ee?fit=crop&w=400&q=80",
      "https://images.unsplash.com/photo-1604076913837-52ab5629fba9?fit=crop&w=400&q=80",
      "https://images.unsplash.com/photo-1550684848-fac1c5b4e853?fit=crop&w=400&q=80",
    ];

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
  Widget _buildSidebar(Color textColor) {
    // Subtle colors reduce visual noise
    final cardColor = isDark
        ? Colors.white.withOpacity(0.04)
        : Colors.black.withOpacity(0.02);
    // A very faint border creates a crisp edge without being distracting
    final borderColor = isDark
        ? Colors.white.withOpacity(0.05)
        : Colors.black.withOpacity(0.05);

    return Column(
      children: [
        // Main Drop Zone
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor, width: 1),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Clean, minimalist icon composition
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
        ),

        const SizedBox(height: 20),

        // Bottom Action Button (Robust InkWell)
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
