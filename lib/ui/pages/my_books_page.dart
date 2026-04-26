import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/bookshelf_model.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/bookshelf_provider.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';

class MyBooksPage extends StatefulWidget {
  const MyBooksPage({super.key});

  @override
  State<MyBooksPage> createState() => _MyBooksPageState();
}

class _MyBooksPageState extends State<MyBooksPage> {
  List<FeedItemModel> _currentlyReading = [];
  bool _loadingReading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<BookshelfProvider>().load();
      _loadCurrentlyReading();
    });
  }

  Future<void> _loadCurrentlyReading() async {
    final auth = context.read<AuthProvider>();
    final ids = auth.currentUser?.readingList ?? [];
    if (ids.isEmpty) {
      if (mounted) setState(() => _loadingReading = false);
      return;
    }
    try {
      final dataService = context.read<AuthProvider>().dataService;
      final items = await dataService.getFeedItemsByIds(ids);
      if (mounted) {
        setState(() {
          _currentlyReading = items;
          _loadingReading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingReading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white54 : Colors.black45;
    final cardColor = isDark ? const Color(0xFF141414) : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    return Material(
      type: MaterialType.transparency,
      child: Container(
      color: bgColor,
      child: Consumer2<AuthProvider, BookshelfProvider>(
        builder: (context, auth, shelves, _) {
          final savedCount = auth.currentUser?.savedPosts.length ?? 0;
          final favCount = auth.currentUser?.favoritePosts.length ?? 0;

          return RefreshIndicator(
            onRefresh: () async {
              await shelves.load(force: true);
              await _loadCurrentlyReading();
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                _CurrentlyReadingSection(
                  items: _currentlyReading,
                  loading: _loadingReading,
                  isDark: isDark,
                  textColor: textColor,
                  subtleColor: subtleColor,
                ),
                const SizedBox(height: 20),
                _LibraryTile(
                  icon: CupertinoIcons.heart,
                  iconColor: const Color(0xFFE11D48),
                  title: 'Favourites',
                  count: favCount,
                  cardColor: cardColor,
                  borderColor: borderColor,
                  textColor: textColor,
                  subtleColor: subtleColor,
                  onTap: () => context.push('/favorites'),
                ),
                const SizedBox(height: 10),
                _LibraryTile(
                  icon: CupertinoIcons.bookmark,
                  iconColor: const Color(0xFF2563EB),
                  title: 'Bookmarks',
                  count: savedCount,
                  cardColor: cardColor,
                  borderColor: borderColor,
                  textColor: textColor,
                  subtleColor: subtleColor,
                  onTap: () => context.push('/saved'),
                ),
                const SizedBox(height: 28),
                _BookshelvesSection(
                  shelves: shelves.shelves,
                  loading: shelves.loading && !shelves.loaded,
                  isDark: isDark,
                  textColor: textColor,
                  subtleColor: subtleColor,
                  cardColor: cardColor,
                  borderColor: borderColor,
                ),
              ],
            ),
          );
        },
      ),
      ),
    );
  }
}

class _CurrentlyReadingSection extends StatelessWidget {
  final List<FeedItemModel> items;
  final bool loading;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;

  const _CurrentlyReadingSection({
    required this.items,
    required this.loading,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox(
        height: 180,
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    if (items.isEmpty) {
      return _EmptyCurrentlyReading(
        isDark: isDark,
        textColor: textColor,
        subtleColor: subtleColor,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Currently reading',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
            Text(
              '${items.length} ${items.length == 1 ? "book" : "books"}',
              style: GoogleFonts.inter(fontSize: 13, color: subtleColor),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 180,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = items[index];
              return _CoverCard(
                item: item,
                isDark: isDark,
                textColor: textColor,
                subtleColor: subtleColor,
                onTap: () => context.push('/post/${item.id}', extra: item),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EmptyCurrentlyReading extends StatelessWidget {
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  const _EmptyCurrentlyReading({
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(CupertinoIcons.book, color: subtleColor, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Nothing currently reading',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Add posts to your reading list to see them here',
                  style: GoogleFonts.inter(fontSize: 12, color: subtleColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverCard extends StatelessWidget {
  final FeedItemModel item;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final VoidCallback onTap;

  const _CoverCard({
    required this.item,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 120,
                height: 140,
                child: (item.imageUrl.isNotEmpty || item.imageMeta != null)
                    ? AppNetworkImage(
                        url: item.imageUrl,
                        meta: item.imageMeta,
                        width: 120,
                        height: 140,
                        fit: BoxFit.cover,
                        errorWidget:
                            _fallback(isDark, subtleColor, item.title),
                      )
                    : _fallback(isDark, subtleColor, item.title),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
            Text(
              item.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(fontSize: 11, color: subtleColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fallback(bool isDark, Color subtleColor, String title) => Container(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.03),
        alignment: Alignment.center,
        child: Text(
          title.isNotEmpty ? title[0].toUpperCase() : '?',
          style: GoogleFonts.playfairDisplay(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: subtleColor.withValues(alpha: 0.4),
          ),
        ),
      );
}

class _LibraryTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final int count;
  final Color cardColor;
  final Color borderColor;
  final Color textColor;
  final Color subtleColor;
  final VoidCallback onTap;

  const _LibraryTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.count,
    required this.cardColor,
    required this.borderColor,
    required this.textColor,
    required this.subtleColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 20),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ),
            Text(
              '$count',
              style: GoogleFonts.inter(fontSize: 14, color: subtleColor),
            ),
            const SizedBox(width: 6),
            Icon(
              CupertinoIcons.chevron_right,
              size: 14,
              color: subtleColor.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookshelvesSection extends StatelessWidget {
  final List<Bookshelf> shelves;
  final bool loading;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final Color cardColor;
  final Color borderColor;

  const _BookshelvesSection({
    required this.shelves,
    required this.loading,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    required this.cardColor,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(
                  CupertinoIcons.collections,
                  size: 18,
                  color: textColor,
                ),
                const SizedBox(width: 8),
                Text(
                  'Bookshelves',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
              ],
            ),
            GestureDetector(
              onTap: () => context.push('/bookshelf/new'),
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Icon(
                    CupertinoIcons.add,
                    size: 16,
                    color: textColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'New',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CupertinoActivityIndicator()),
          )
        else if (shelves.isEmpty)
          _EmptyBookshelves(
            isDark: isDark,
            textColor: textColor,
            subtleColor: subtleColor,
          )
        else
          ...shelves.map(
            (s) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _BookshelfCard(
                shelf: s,
                cardColor: cardColor,
                borderColor: borderColor,
                textColor: textColor,
                subtleColor: subtleColor,
                onTap: () => context.push('/bookshelf/${s.id}'),
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyBookshelves extends StatelessWidget {
  final bool isDark;
  final Color textColor;
  final Color subtleColor;

  const _EmptyBookshelves({
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(
            CupertinoIcons.collections,
            size: 32,
            color: subtleColor.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 10),
          Text(
            'No bookshelves yet',
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Let's start your little library",
            style: GoogleFonts.inter(fontSize: 13, color: subtleColor),
          ),
          const SizedBox(height: 16),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
            color: isDark ? Colors.white : Colors.black,
            borderRadius: BorderRadius.circular(24),
            onPressed: () => context.push('/bookshelf/new'),
            child: Text(
              'Create bookshelf',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.black : Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookshelfCard extends StatelessWidget {
  final Bookshelf shelf;
  final Color cardColor;
  final Color borderColor;
  final Color textColor;
  final Color subtleColor;
  final VoidCallback onTap;

  const _BookshelfCard({
    required this.shelf,
    required this.cardColor,
    required this.borderColor,
    required this.textColor,
    required this.subtleColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: subtleColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                CupertinoIcons.book,
                size: 20,
                color: textColor.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          shelf.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                        ),
                      ),
                      if (shelf.isPrivate) ...[
                        const SizedBox(width: 6),
                        Icon(
                          CupertinoIcons.lock_fill,
                          size: 12,
                          color: subtleColor,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${shelf.itemCount} ${shelf.itemCount == 1 ? "book" : "books"}',
                    style: GoogleFonts.inter(fontSize: 12, color: subtleColor),
                  ),
                ],
              ),
            ),
            Icon(
              CupertinoIcons.chevron_right,
              size: 14,
              color: subtleColor.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}
