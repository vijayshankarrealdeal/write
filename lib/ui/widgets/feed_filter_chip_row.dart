import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/services/api/api_data_service.dart';

/// Horizontal strip of filter chips on the main feed. Lazy-loads facets
/// the first time it builds, then toggles `FeedProvider` filter state
/// in place. The chip strip itself does not fetch the filtered feed —
/// `FeedProvider.toggleFilter` is the single owner of that effect.
///
/// Layout:
///   ┌───────┬──────────┬──────────┬──────────┬──────────┬───────────┐
///   │  ☰    │  Fiction │ #noir    │ Story    │ ...      │ Clear all │
///   └───────┴──────────┴──────────┴──────────┴──────────┴───────────┘
///   filters             top facets (mixed)             clear (when active)
class FeedFilterChipRow extends StatefulWidget {
  /// Chip count surfaced inline before the "more" sheet kicks in.
  /// 6 fits a phone in landscape without wrapping; the rest live in
  /// the sheet.
  final int inlineLimit;

  /// Optional injectable loader for tests; production reads through
  /// `FeedProvider.ensureFacets`.
  final Future<FeedFacets> Function()? loader;

  const FeedFilterChipRow({
    super.key,
    this.inlineLimit = 6,
    this.loader,
  });

  @override
  State<FeedFilterChipRow> createState() => _FeedFilterChipRowState();
}

class _FeedFilterChipRowState extends State<FeedFilterChipRow> {
  Future<FeedFacets>? _future;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _future = widget.loader != null
            ? widget.loader!()
            : context.read<FeedProvider>().ensureFacets();
      });
    });
  }

  /// Mix the top entries of every column into one ordered list. Each
  /// chip carries its kind so the toggle hits the right `FeedProvider`
  /// set. Round-robin keeps a single tall column from drowning the
  /// others when the long-tail is short.
  List<_FacetEntryWithKind> _mixed(FeedFacets facets) {
    final out = <_FacetEntryWithKind>[];
    final genres = facets.genres;
    final tags = facets.tags;
    final types = facets.writingTypes;
    final maxLen = [genres.length, tags.length, types.length]
        .fold<int>(0, (a, b) => a > b ? a : b);
    for (int i = 0; i < maxLen; i++) {
      if (i < genres.length) {
        out.add(_FacetEntryWithKind(kind: 'genre', entry: genres[i]));
      }
      if (i < tags.length) {
        out.add(_FacetEntryWithKind(kind: 'tag', entry: tags[i]));
      }
      if (i < types.length) {
        out.add(_FacetEntryWithKind(kind: 'type', entry: types[i]));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Consumer<FeedProvider>(
      builder: (context, feed, _) {
        return SizedBox(
          height: 44,
          child: FutureBuilder<FeedFacets>(
            future: _future,
            builder: (context, snap) {
              final facets = snap.data ??
                  const FeedFacets(genres: [], tags: [], writingTypes: []);
              final mixed = _mixed(facets);
              if (mixed.isEmpty && !feed.hasActiveFilters) {
                // No facets known yet and no filters set — render
                // nothing rather than an empty bar.
                return const SizedBox.shrink();
              }

              final inline = mixed.take(widget.inlineLimit).toList();
              final hasOverflow = mixed.length > inline.length;

              return ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _MoreFiltersChip(
                    isDark: isDark,
                    onTap: () => _openSheet(context, feed),
                    activeCount:
                        feed.filterGenres.length +
                        feed.filterTags.length +
                        feed.filterWritingTypes.length,
                  ),
                  for (final m in inline) ...[
                    const SizedBox(width: 8),
                    _Chip(
                      label: m.label,
                      isActive: feed.isActive(m.kind, m.entry.value),
                      isDark: isDark,
                      onTap: () => feed.toggleFilter(m.kind, m.entry.value),
                    ),
                  ],
                  if (hasOverflow) ...[
                    const SizedBox(width: 8),
                    _Chip(
                      label: 'More…',
                      isActive: false,
                      isDark: isDark,
                      onTap: () => _openSheet(context, feed),
                    ),
                  ],
                  if (feed.hasActiveFilters) ...[
                    const SizedBox(width: 12),
                    _ClearAllChip(
                      isDark: isDark,
                      onTap: feed.clearFilters,
                    ),
                  ],
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _openSheet(BuildContext context, FeedProvider feed) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF111111) : Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return _FilterSheet(
          facets: feed.cachedFacets ??
              const FeedFacets(genres: [], tags: [], writingTypes: []),
        );
      },
    );
  }
}

class _FacetEntryWithKind {
  final String kind; // 'genre' | 'tag' | 'type'
  final FacetEntry entry;
  const _FacetEntryWithKind({required this.kind, required this.entry});

  String get label {
    if (kind == 'tag') return '#${entry.value}';
    return entry.value;
  }
}

extension on FeedProvider {
  bool isActive(String kind, String value) {
    switch (kind) {
      case 'genre':
        return filterGenres.contains(value);
      case 'tag':
        return filterTags.contains(value);
      case 'type':
        return filterWritingTypes.contains(value);
      default:
        return false;
    }
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool isActive;
  final bool isDark;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.isActive,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final activeBg = const Color(0xFF2563EB);
    final activeFg = Colors.white;
    final inactiveBg = isDark
        ? Colors.white.withValues(alpha: 0.07)
        : Colors.black.withValues(alpha: 0.04);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: isActive ? activeBg : inactiveBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive
                ? activeBg
                : (isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.06)),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isActive ? activeFg : textColor,
          ),
        ),
      ),
    );
  }
}

class _MoreFiltersChip extends StatelessWidget {
  final bool isDark;
  final int activeCount;
  final VoidCallback onTap;

  const _MoreFiltersChip({
    required this.isDark,
    required this.onTap,
    required this.activeCount,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final hasActive = activeCount > 0;
    final fg = hasActive ? Colors.white : textColor;
    final bg = hasActive
        ? const Color(0xFF2563EB)
        : (isDark
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.black.withValues(alpha: 0.04));
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: hasActive
                ? const Color(0xFF2563EB)
                : (isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.06)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.slider_horizontal_3, size: 14, color: fg),
            const SizedBox(width: 6),
            Text(
              hasActive ? 'Filters · $activeCount' : 'Filters',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClearAllChip extends StatelessWidget {
  final bool isDark;
  final VoidCallback onTap;

  const _ClearAllChip({required this.isDark, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: textColor.withValues(alpha: 0.2),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.clear, size: 12, color: textColor),
            const SizedBox(width: 6),
            Text(
              'Clear all',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterSheet extends StatelessWidget {
  final FeedFacets facets;
  const _FilterSheet({required this.facets});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final media = MediaQuery.of(context);

    return Consumer<FeedProvider>(
      builder: (context, feed, _) {
        return Padding(
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: media.size.height * 0.75,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white24 : Colors.black12,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Filter feed',
                          style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: textColor,
                          ),
                        ),
                      ),
                      if (feed.hasActiveFilters)
                        TextButton(
                          onPressed: () {
                            feed.clearFilters();
                            Navigator.of(context).maybePop();
                          },
                          child: const Text('Clear all'),
                        ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    children: [
                      _SheetSection(
                        title: 'Genres',
                        kind: 'genre',
                        entries: facets.genres,
                        feed: feed,
                        isDark: isDark,
                      ),
                      _SheetSection(
                        title: 'Tags',
                        kind: 'tag',
                        entries: facets.tags,
                        feed: feed,
                        isDark: isDark,
                        prefix: '#',
                      ),
                      _SheetSection(
                        title: 'Writing types',
                        kind: 'type',
                        entries: facets.writingTypes,
                        feed: feed,
                        isDark: isDark,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SheetSection extends StatelessWidget {
  final String title;
  final String kind;
  final List<FacetEntry> entries;
  final FeedProvider feed;
  final bool isDark;
  final String prefix;

  const _SheetSection({
    required this.title,
    required this.kind,
    required this.entries,
    required this.feed,
    required this.isDark,
    this.prefix = '',
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: textColor.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: entries
                .map((e) => _Chip(
                      label: '$prefix${e.value}',
                      isActive: feed.isActive(kind, e.value),
                      isDark: isDark,
                      onTap: () => feed.toggleFilter(kind, e.value),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }
}
