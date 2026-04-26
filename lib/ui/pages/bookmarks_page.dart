import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/bookmark_model.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/bookmark_provider.dart';
import 'package:inkspacex/services/app_log.dart';

/// "My Bookmarks" — every paragraph the user has marked, grouped by
/// writing. Reached from the profile hub. Tap a row to open the reader
/// at the section the bookmark targets; long-press to delete.
class BookmarksPage extends StatefulWidget {
  const BookmarksPage({super.key});

  @override
  State<BookmarksPage> createState() => _BookmarksPageState();
}

class _BookmarksPageState extends State<BookmarksPage> {
  Map<String, FeedItemModel?> _itemCache = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final p = context.read<BookmarkProvider>();
      // Always re-fetch on open — bookmarks added on another device
      // would otherwise stay invisible until a manual refresh.
      p.loadAllForUser().then((_) => _hydrateFeedItems());
    });
  }

  Future<void> _hydrateFeedItems() async {
    if (!mounted) return;
    final marks = context.read<BookmarkProvider>().all;
    final ids = marks.map((b) => b.feedItemId).toSet().toList();
    if (ids.isEmpty) return;
    try {
      final items =
          await context.read<AuthProvider>().dataService.getFeedItemsByIds(ids);
      if (!mounted) return;
      setState(() {
        _itemCache = {for (final it in items) it.id: it};
      });
    } catch (e) {
      log.w('[bookmarks] feed item hydration failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white54 : Colors.black45;
    final cardColor = isDark ? const Color(0xFF141414) : Colors.white;

    return Consumer<BookmarkProvider>(
      builder: (context, provider, _) {
        final groups = provider.byFeedItem;
        final keys = groups.keys.toList()
          ..sort((a, b) {
            final aMax = groups[a]!.first.updatedAt;
            final bMax = groups[b]!.first.updatedAt;
            return bMax.compareTo(aMax);
          });

        return Scaffold(
          backgroundColor: bgColor,
          appBar: AppBar(
            title: Text(
              'Bookmarks',
              style: GoogleFonts.inter(
                color: textColor,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            backgroundColor: bgColor,
            elevation: 0,
          ),
          body: provider.loading && provider.all.isEmpty
              ? const Center(child: CupertinoActivityIndicator())
              : provider.all.isEmpty
                  ? _empty(textColor, subtleColor)
                  : RefreshIndicator(
                      onRefresh: () async {
                        await provider.loadAllForUser();
                        await _hydrateFeedItems();
                      },
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        itemCount: keys.length,
                        itemBuilder: (_, gi) {
                          final feedItemId = keys[gi];
                          final marks = groups[feedItemId]!;
                          final item = _itemCache[feedItemId];
                          return _BookmarkGroup(
                            feedItem: item,
                            marks: marks,
                            cardColor: cardColor,
                            textColor: textColor,
                            subtleColor: subtleColor,
                            onOpen: (b) => _openMark(item, b),
                            onDelete: (b) => provider.deleteBookmark(b.id),
                          );
                        },
                      ),
                    ),
        );
      },
    );
  }

  void _openMark(FeedItemModel? item, BookmarkModel mark) {
    if (item == null) return;
    context.push('/post/${item.id}', extra: item);
  }

  Widget _empty(Color textColor, Color subtleColor) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(CupertinoIcons.bookmark,
                  size: 56, color: subtleColor),
              const SizedBox(height: 16),
              Text(
                'No bookmarks yet',
                style: GoogleFonts.inter(
                  color: textColor,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Long-press a paragraph in the reader to mark it for later.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: subtleColor,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
}

class _BookmarkGroup extends StatelessWidget {
  const _BookmarkGroup({
    required this.feedItem,
    required this.marks,
    required this.cardColor,
    required this.textColor,
    required this.subtleColor,
    required this.onOpen,
    required this.onDelete,
  });

  final FeedItemModel? feedItem;
  final List<BookmarkModel> marks;
  final Color cardColor;
  final Color textColor;
  final Color subtleColor;
  final void Function(BookmarkModel) onOpen;
  final void Function(BookmarkModel) onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding:
                const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(
              feedItem?.title ?? 'Untitled writing',
              style: GoogleFonts.inter(
                color: textColor,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          for (final m in marks) ...[
            const Divider(height: 1),
            ListTile(
              leading: Container(
                width: 4,
                height: 32,
                decoration: BoxDecoration(
                  color: _parseColor(m.color, fallback: textColor),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              title: Text(
                m.label?.isNotEmpty == true
                    ? m.label!
                    : 'Section ${m.sectionIndex + 1} · ¶${m.paragraphIdx + 1}',
                style: GoogleFonts.inter(
                  color: textColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                _relative(m.updatedAt),
                style: GoogleFonts.inter(
                  color: subtleColor,
                  fontSize: 12,
                ),
              ),
              trailing: IconButton(
                icon: Icon(CupertinoIcons.delete, color: subtleColor),
                onPressed: () => onDelete(m),
              ),
              onTap: () => onOpen(m),
            ),
          ],
        ],
      ),
    );
  }

  static Color _parseColor(String hex, {required Color fallback}) {
    var s = hex.replaceFirst('#', '').toUpperCase();
    if (s.length == 6) s = 'FF$s';
    final v = int.tryParse(s, radix: 16);
    if (v == null) return fallback;
    return Color(v);
  }

  static String _relative(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}
