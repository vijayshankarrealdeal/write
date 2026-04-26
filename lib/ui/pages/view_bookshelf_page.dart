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

class ViewBookshelfPage extends StatefulWidget {
  final String bookshelfId;
  const ViewBookshelfPage({super.key, required this.bookshelfId});

  @override
  State<ViewBookshelfPage> createState() => _ViewBookshelfPageState();
}

class _ViewBookshelfPageState extends State<ViewBookshelfPage> {
  Map<String, FeedItemModel> _items = {};
  String _lastLoadedKey = '';
  bool _loading = true;
  bool _fetchInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final shelves = context.read<BookshelfProvider>();
      if (!shelves.loaded) shelves.load();
      _loadItemsIfNeeded();
    });
  }

  String _keyFor(List<String> ids) {
    final copy = List<String>.from(ids)..sort();
    return copy.join(',');
  }

  Future<void> _loadItemsIfNeeded() async {
    if (_fetchInFlight) return;
    final shelf = context.read<BookshelfProvider>().byId(widget.bookshelfId);
    final ids = shelf?.itemIds ?? const <String>[];
    final key = _keyFor(ids);
    if (key == _lastLoadedKey) {
      if (_loading && mounted) setState(() => _loading = false);
      return;
    }

    if (ids.isEmpty) {
      if (mounted) {
        setState(() {
          _items = {};
          _lastLoadedKey = key;
          _loading = false;
        });
      }
      return;
    }

    _fetchInFlight = true;
    if (mounted && !_loading) setState(() => _loading = true);
    try {
      final dataService = context.read<AuthProvider>().dataService;
      final fetched = await dataService.getFeedItemsByIds(ids);
      if (mounted) {
        setState(() {
          _items = {for (final i in fetched) i.id: i};
          _lastLoadedKey = key;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    } finally {
      _fetchInFlight = false;
    }
  }

  void _confirmDelete(BuildContext context, Bookshelf shelf) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(
          'Delete "${shelf.name}"?',
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
        content: const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('This bookshelf and its contents will be removed.'),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(ctx).pop();
              context
                  .read<BookshelfProvider>()
                  .delete(shelf.id)
                  .then((_) {
                if (mounted) context.pop();
              });
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
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

    return Consumer<BookshelfProvider>(
      builder: (context, shelves, _) {
        final shelf = shelves.byId(widget.bookshelfId);
        if (shelf == null) {
          return Scaffold(
            backgroundColor: bgColor,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              iconTheme: IconThemeData(color: textColor),
            ),
            body: Center(
              child: shelves.loading
                  ? const CupertinoActivityIndicator()
                  : Text(
                      'Bookshelf not found',
                      style: GoogleFonts.inter(color: textColor),
                    ),
            ),
          );
        }

        // Re-fetch items if the shelf's contents changed (e.g. after picker returns).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _loadItemsIfNeeded();
        });

        final visibleItems = shelf.itemIds
            .map((id) => _items[id])
            .whereType<FeedItemModel>()
            .toList();
        final isEmpty = shelf.itemIds.isEmpty;

        return Scaffold(
          backgroundColor: bgColor,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            iconTheme: IconThemeData(color: textColor),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    shelf.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                ),
                if (shelf.isPrivate) ...[
                  const SizedBox(width: 6),
                  Icon(CupertinoIcons.lock_fill, size: 14, color: subtleColor),
                ],
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Delete bookshelf',
                icon: Icon(
                  CupertinoIcons.delete,
                  size: 20,
                  color: subtleColor,
                ),
                onPressed: () => _confirmDelete(context, shelf),
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  children: [
                    if (shelf.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            shelf.description,
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              color: subtleColor,
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: _loading && visibleItems.isEmpty && !isEmpty
                          ? const Center(child: CupertinoActivityIndicator())
                          : isEmpty
                              ? _EmptyState(
                                  isDark: isDark,
                                  textColor: textColor,
                                  subtleColor: subtleColor,
                                  onAdd: () => context.push(
                                    '/bookshelf/${shelf.id}/add',
                                  ),
                                )
                              : ListView.separated(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    8,
                                    20,
                                    100,
                                  ),
                                  itemCount: visibleItems.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 12),
                                  itemBuilder: (context, index) {
                                    final item = visibleItems[index];
                                    return _ShelfItemCard(
                                      item: item,
                                      isDark: isDark,
                                      textColor: textColor,
                                      subtleColor: subtleColor,
                                      cardColor: cardColor,
                                      borderColor: borderColor,
                                      onTap: () => context.push(
                                        '/post/${item.id}',
                                        extra: item,
                                      ),
                                      onRemove: () {
                                        context
                                            .read<BookshelfProvider>()
                                            .removeItem(shelf.id, item.id);
                                      },
                                    );
                                  },
                                ),
                    ),
                    if (!isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                        child: SizedBox(
                          width: double.infinity,
                          child: CupertinoButton(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF2563EB),
                            borderRadius: BorderRadius.circular(28),
                            onPressed: () =>
                                context.push('/bookshelf/${shelf.id}/add'),
                            child: Text(
                              'Add books',
                              style: GoogleFonts.inter(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.black : Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final VoidCallback onAdd;

  const _EmptyState({
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
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
              CupertinoIcons.collections,
              size: 36,
              color: subtleColor.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            "No books yet",
            style: GoogleFonts.inter(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "Let's start your little library",
            style: GoogleFonts.inter(fontSize: 14, color: subtleColor),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 16),
              color: isDark ? Colors.white : const Color(0xFF2563EB),
              borderRadius: BorderRadius.circular(28),
              onPressed: onAdd,
              child: Text(
                'Add books',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.black : Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShelfItemCard extends StatelessWidget {
  final FeedItemModel item;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final Color cardColor;
  final Color borderColor;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _ShelfItemCard({
    required this.item,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    required this.cardColor,
    required this.borderColor,
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
          border: Border.all(color: borderColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            SizedBox(
              width: 80,
              height: 80,
              child: (item.imageUrl.isNotEmpty || item.imageMeta != null)
                  ? AppNetworkImage(
                      url: item.imageUrl,
                      meta: item.imageMeta,
                      width: 80,
                      height: 80,
                      fit: BoxFit.cover,
                      errorWidget: Container(
                        color: isDark ? Colors.white10 : Colors.grey[200],
                        child: Icon(
                          CupertinoIcons.photo,
                          color: subtleColor,
                          size: 22,
                        ),
                      ),
                    )
                  : Container(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.black.withValues(alpha: 0.03),
                      alignment: Alignment.center,
                      child: Text(
                        item.title.isNotEmpty
                            ? item.title[0].toUpperCase()
                            : '?',
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: subtleColor.withValues(alpha: 0.3),
                        ),
                      ),
                    ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.author,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: subtleColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              icon: Icon(
                CupertinoIcons.minus_circle,
                size: 20,
                color: subtleColor,
              ),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}
