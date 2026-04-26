import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/ui/pages/tag_feed_page.dart';

/// Test seam — production code falls through to the real API.
typedef FacetsLoader = Future<FeedFacets> Function();

/// Browse-by-facet surface. Lists the top genres / tags / writing-types
/// served by `/api/feed/facets`, ordered by count, with a search box that
/// filters the visible chips client-side. Tapping a chip pushes a
/// [TagFeedPage] for the selected facet.
class ExplorePage extends StatefulWidget {
  final FacetsLoader? loader;
  const ExplorePage({super.key, this.loader});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  final TextEditingController _query = TextEditingController();
  Future<FeedFacets>? _future;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final f = _resolveLoader()();
      setState(() {
        _future = f;
      });
    });
    _query.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  FacetsLoader _resolveLoader() {
    final injected = widget.loader;
    if (injected != null) return injected;
    return () => context.read<AuthProvider>().dataService.getFeedFacets();
  }

  Future<void> _refresh() async {
    final f = _resolveLoader()();
    setState(() {
      _future = f;
    });
    await f;
  }

  List<FacetEntry> _filter(List<FacetEntry> entries) {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return entries;
    return entries
        .where((e) => e.value.toLowerCase().contains(q))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white54 : Colors.black45;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFF8F9FA);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          'Explore',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: _SearchField(
              controller: _query,
              isDark: isDark,
              hint: 'Search tags, genres, types',
            ),
          ),
          Expanded(
            child: FutureBuilder<FeedFacets>(
              future: _future,
              builder: (context, snap) {
                if (_future == null ||
                    snap.connectionState != ConnectionState.done) {
                  return const Center(child: CupertinoActivityIndicator());
                }
                final facets = snap.data ?? const FeedFacets(
                  genres: [],
                  tags: [],
                  writingTypes: [],
                );
                if (facets.isEmpty) {
                  return _EmptyFacets(
                    textColor: textColor,
                    subtleColor: subtleColor,
                    onRetry: _refresh,
                  );
                }

                final genres = _filter(facets.genres);
                final tags = _filter(facets.tags);
                final types = _filter(facets.writingTypes);
                final hasAny =
                    genres.isNotEmpty || tags.isNotEmpty || types.isNotEmpty;

                if (!hasAny) {
                  return _EmptyFacets(
                    textColor: textColor,
                    subtleColor: subtleColor,
                    title: 'No matches',
                    subtitle: 'Try a shorter search.',
                    onRetry: () => _query.clear(),
                    retryLabel: 'Clear search',
                  );
                }

                return RefreshIndicator(
                  onRefresh: _refresh,
                  color: textColor,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    children: [
                      if (genres.isNotEmpty)
                        _FacetSection(
                          title: 'Genres',
                          entries: genres,
                          isDark: isDark,
                          textColor: textColor,
                          subtleColor: subtleColor,
                          onTap: (e) => context.push(
                            '/tag-feed/genre/${Uri.encodeComponent(e.value)}',
                          ),
                        ),
                      if (tags.isNotEmpty)
                        _FacetSection(
                          title: 'Tags',
                          entries: tags,
                          isDark: isDark,
                          textColor: textColor,
                          subtleColor: subtleColor,
                          prefix: '#',
                          onTap: (e) => context.push(
                            '/tag-feed/tag/${Uri.encodeComponent(e.value)}',
                          ),
                        ),
                      if (types.isNotEmpty)
                        _FacetSection(
                          title: 'Writing types',
                          entries: types,
                          isDark: isDark,
                          textColor: textColor,
                          subtleColor: subtleColor,
                          onTap: (e) => context.push(
                            '/tag-feed/type/${Uri.encodeComponent(e.value)}',
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final bool isDark;
  final String hint;

  const _SearchField({
    required this.controller,
    required this.isDark,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final fillColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.04);
    return TextField(
      controller: controller,
      style: GoogleFonts.inter(fontSize: 14, color: textColor),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.inter(
          fontSize: 14,
          color: textColor.withValues(alpha: 0.5),
        ),
        prefixIcon: Icon(
          CupertinoIcons.search,
          size: 18,
          color: textColor.withValues(alpha: 0.5),
        ),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: Icon(CupertinoIcons.clear_circled_solid,
                    size: 18, color: textColor.withValues(alpha: 0.4)),
                onPressed: controller.clear,
              ),
        filled: true,
        fillColor: fillColor,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _FacetSection extends StatelessWidget {
  final String title;
  final List<FacetEntry> entries;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final ValueChanged<FacetEntry> onTap;
  final String prefix;

  const _FacetSection({
    required this.title,
    required this.entries,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    required this.onTap,
    this.prefix = '',
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
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
                .map((e) => _FacetChip(
                      label: '$prefix${e.value}',
                      count: e.count,
                      isDark: isDark,
                      textColor: textColor,
                      subtleColor: subtleColor,
                      onTap: () => onTap(e),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _FacetChip extends StatelessWidget {
  final String label;
  final int count;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final VoidCallback onTap;

  const _FacetChip({
    required this.label,
    required this.count,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.07)
              : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.06),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: subtleColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyFacets extends StatelessWidget {
  final Color textColor;
  final Color subtleColor;
  final String title;
  final String subtitle;
  final VoidCallback onRetry;
  final String retryLabel;

  const _EmptyFacets({
    required this.textColor,
    required this.subtleColor,
    required this.onRetry,
    this.title = 'Nothing to explore yet',
    this.subtitle = 'New genres and tags will appear as writing is published.',
    this.retryLabel = 'Retry',
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.compass, size: 48, color: subtleColor),
            const SizedBox(height: 12),
            Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: subtleColor,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: onRetry, child: Text(retryLabel)),
          ],
        ),
      ),
    );
  }
}
