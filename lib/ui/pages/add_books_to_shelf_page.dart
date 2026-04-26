import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/bookshelf_provider.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';

class AddBooksToShelfPage extends StatefulWidget {
  final String bookshelfId;
  const AddBooksToShelfPage({super.key, required this.bookshelfId});

  @override
  State<AddBooksToShelfPage> createState() => _AddBooksToShelfPageState();
}

class _AddBooksToShelfPageState extends State<AddBooksToShelfPage> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  List<FeedItemModel> _results = [];
  bool _loading = true;
  String _query = '';
  final Set<String> _selected = {};
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _loadPopular();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadPopular() async {
    setState(() => _loading = true);
    try {
      final dataService = context.read<AuthProvider>().dataService;
      final items = await dataService.getPopularFeedItems(limit: 30);
      if (mounted) {
        setState(() {
          _results = items;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runSearch(String q) async {
    setState(() => _loading = true);
    try {
      final dataService = context.read<AuthProvider>().dataService;
      final items = q.isEmpty
          ? await dataService.getPopularFeedItems(limit: 30)
          : await dataService.searchFeedItems(q, limit: 40);
      if (mounted && q == _query) {
        setState(() {
          _results = items;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onQueryChanged(String q) {
    _query = q.trim();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _runSearch(_query);
    });
  }

  Future<void> _addSelected() async {
    if (_selected.isEmpty || _adding) return;
    setState(() => _adding = true);
    final shelves = context.read<BookshelfProvider>();
    await shelves.addItems(widget.bookshelfId, _selected.toList());
    if (!mounted) return;
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white54 : Colors.black45;
    final fieldColor = isDark ? const Color(0xFF141414) : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);

    final shelf = context.watch<BookshelfProvider>().byId(widget.bookshelfId);
    final alreadyInShelf = shelf?.itemIds.toSet() ?? <String>{};

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
        title: Text(
          shelf?.name ?? 'Add books',
          style: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Container(
                decoration: BoxDecoration(
                  color: fieldColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: borderColor),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      CupertinoIcons.search,
                      size: 18,
                      color: subtleColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: CupertinoTextField(
                        controller: _searchCtrl,
                        placeholder: 'Search',
                        placeholderStyle: GoogleFonts.inter(
                          fontSize: 14,
                          color: subtleColor,
                        ),
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          color: textColor,
                        ),
                        decoration: const BoxDecoration(),
                        onChanged: _onQueryChanged,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CupertinoActivityIndicator())
                  : _results.isEmpty
                      ? Center(
                          child: Text(
                            _query.isEmpty
                                ? 'No books available'
                                : 'No matches for "$_query"',
                            style: GoogleFonts.inter(color: subtleColor),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 120),
                          itemCount: _results.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final item = _results[index];
                            final already = alreadyInShelf.contains(item.id);
                            final selected = _selected.contains(item.id);
                            return _PickerRow(
                              item: item,
                              isDark: isDark,
                              textColor: textColor,
                              subtleColor: subtleColor,
                              fieldColor: fieldColor,
                              borderColor: borderColor,
                              already: already,
                              selected: selected,
                              onTap: already
                                  ? null
                                  : () => setState(() {
                                        if (selected) {
                                          _selected.remove(item.id);
                                        } else {
                                          _selected.add(item.id);
                                        }
                                      }),
                            );
                          },
                        ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  color: _selected.isEmpty
                      ? (isDark ? Colors.white24 : Colors.black26)
                      : (isDark ? Colors.white : const Color(0xFF2563EB)),
                  borderRadius: BorderRadius.circular(28),
                  onPressed: _selected.isEmpty || _adding ? null : _addSelected,
                  child: _adding
                      ? const CupertinoActivityIndicator(color: Colors.white)
                      : Text(
                          _selected.isEmpty
                              ? 'Add books'
                              : 'Add ${_selected.length} ${_selected.length == 1 ? "book" : "books"}',
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
    );
  }
}

class _PickerRow extends StatelessWidget {
  final FeedItemModel item;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final Color fieldColor;
  final Color borderColor;
  final bool already;
  final bool selected;
  final VoidCallback? onTap;

  const _PickerRow({
    required this.item,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    required this.fieldColor,
    required this.borderColor,
    required this.already,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Opacity(
        opacity: already ? 0.45 : 1,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: fieldColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? const Color(0xFF2563EB) : borderColor,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 52,
                  height: 52,
                  child: (item.imageUrl.isNotEmpty || item.imageMeta != null)
                      ? AppNetworkImage(
                          url: item.imageUrl,
                          meta: item.imageMeta,
                          width: 52,
                          height: 52,
                          fit: BoxFit.cover,
                          errorWidget: Container(
                            color: isDark ? Colors.white10 : Colors.grey[200],
                          ),
                        )
                      : Container(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.05)
                              : Colors.black.withValues(alpha: 0.04),
                          alignment: Alignment.center,
                          child: Text(
                            item.title.isNotEmpty
                                ? item.title[0].toUpperCase()
                                : '?',
                            style: GoogleFonts.playfairDisplay(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: subtleColor,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      already ? 'Already in shelf' : item.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: subtleColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _Checkbox(selected: selected, disabled: already),
            ],
          ),
        ),
      ),
    );
  }
}

class _Checkbox extends StatelessWidget {
  final bool selected;
  final bool disabled;
  const _Checkbox({required this.selected, required this.disabled});

  @override
  Widget build(BuildContext context) {
    if (disabled) {
      return Icon(
        CupertinoIcons.checkmark_alt_circle_fill,
        size: 22,
        color: Colors.grey.withValues(alpha: 0.5),
      );
    }
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF2563EB) : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? const Color(0xFF2563EB) : Colors.grey,
          width: 1.4,
        ),
      ),
      child: selected
          ? const Icon(Icons.check, size: 14, color: Colors.white)
          : null,
    );
  }
}
