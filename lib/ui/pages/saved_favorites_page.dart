import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
enum CollectionType { saved, favorites }

class SavedFavoritesPage extends StatefulWidget {
  final CollectionType type;
  const SavedFavoritesPage({super.key, required this.type});

  @override
  State<SavedFavoritesPage> createState() => _SavedFavoritesPageState();
}

class _SavedFavoritesPageState extends State<SavedFavoritesPage> {
  List<FeedItemModel>? _items;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    final auth = context.read<AuthProvider>();
    final ids = widget.type == CollectionType.saved
        ? auth.currentUser?.savedPosts ?? []
        : auth.currentUser?.favoritePosts ?? [];
    if (ids.isEmpty) {
      setState(() {
        _items = [];
        _loading = false;
      });
      return;
    }
    try {
      final dataService = context.read<AuthProvider>().dataService;
      final items = await dataService.getFeedItemsByIds(ids);
      if (mounted) setState(() {
        _items = items;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() {
        _items = [];
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white54 : Colors.black45;
    final cardColor = isDark ? const Color(0xFF141414) : Colors.white;
    final isSaved = widget.type == CollectionType.saved;
    final title = isSaved ? 'Saved Posts' : 'Favourites';
    final emptyIcon = isSaved ? CupertinoIcons.bookmark : CupertinoIcons.star;
    final emptyTitle = isSaved ? 'No saved posts yet' : 'No favourites yet';
    final emptySubtitle = isSaved
        ? 'Posts you bookmark will appear here'
        : 'Posts you favourite will appear here';

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(
          title,
          style: GoogleFonts.inter(
            color: textColor,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : _items == null || _items!.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.05)
                              : Colors.black.withValues(alpha: 0.04),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          emptyIcon,
                          size: 36,
                          color: subtleColor.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        emptyTitle,
                        style: GoogleFonts.inter(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        emptySubtitle,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          color: subtleColor,
                        ),
                      ),
                    ],
                  ),
                )
              : Consumer<AuthProvider>(
                  builder: (context, auth, _) {
                    // Re-filter based on current state (optimistic removals)
                    final currentIds = isSaved
                        ? auth.currentUser?.savedPosts ?? []
                        : auth.currentUser?.favoritePosts ?? [];
                    final filtered = _items!
                        .where((item) => currentIds.contains(item.id))
                        .toList();

                    if (filtered.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(emptyIcon, size: 36,
                                color: subtleColor.withValues(alpha: 0.5)),
                            const SizedBox(height: 16),
                            Text(emptyTitle,
                                style: GoogleFonts.inter(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                    color: textColor)),
                          ],
                        ),
                      );
                    }

                    return ListView.separated(
                      padding: const EdgeInsets.all(20),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        return _SavedItemCard(
                          item: item,
                          isDark: isDark,
                          textColor: textColor,
                          subtleColor: subtleColor,
                          cardColor: cardColor,
                          isSaved: isSaved,
                          onTap: () => context.push('/post/${item.id}', extra: item),
                          onRemove: () {
                            if (isSaved) {
                              auth.toggleSave(item.id);
                            } else {
                              auth.toggleFavorite(item.id);
                            }
                          },
                        );
                      },
                    );
                  },
                ),
    );
  }
}

class _SavedItemCard extends StatelessWidget {
  final FeedItemModel item;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final Color cardColor;
  final bool isSaved;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _SavedItemCard({
    required this.item,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    required this.cardColor,
    required this.isSaved,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.06),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            // Cover image
            if (item.imageUrl.isNotEmpty)
              SizedBox(
                width: 90,
                height: 90,
                child: CachedNetworkImage(
                  imageUrl: item.imageUrl,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    color: isDark ? Colors.white10 : Colors.grey[200],
                  ),
                  errorWidget: (_, __, ___) => Container(
                    color: isDark ? Colors.white10 : Colors.grey[200],
                    child: Icon(CupertinoIcons.photo,
                        color: subtleColor, size: 24),
                  ),
                ),
              )
            else
              Container(
                width: 90,
                height: 90,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.03),
                child: Center(
                  child: Text(
                    item.title.isNotEmpty ? item.title[0].toUpperCase() : '?',
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: subtleColor.withValues(alpha: 0.3),
                    ),
                  ),
                ),
              ),

            // Content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: GoogleFonts.inter(
                        fontSize: 15,
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
                        fontSize: 13,
                        color: subtleColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${item.sections.length} ${item.sections.length == 1 ? "section" : "sections"}',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: subtleColor.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Remove button
            GestureDetector(
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Icon(
                  isSaved
                      ? CupertinoIcons.bookmark_fill
                      : CupertinoIcons.star_fill,
                  size: 20,
                  color: const Color(0xFF2563EB),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
