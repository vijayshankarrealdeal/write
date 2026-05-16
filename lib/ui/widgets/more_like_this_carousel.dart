import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/ui/pages/post_detail_page.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/author_link.dart';

/// "More like this" — semantic-neighbour carousel rendered at the bottom
/// of the read page. Powered by `/api/ai/recommendations/similar/{id}`
/// (pgvector cosine KNN). Quietly hides itself when:
///   - the seed has no embedding yet (backfill not finished, or fresh draft)
///   - the request fails for any reason
///   - the engine returns an empty list
///
/// Card layout matches the standard feed card so the user gets visual
/// continuity across surfaces.
/// Test seam: tests inject their own loader instead of standing up an
/// `AuthProvider`. Production code never passes this — it falls through
/// to `context.read<AuthProvider>().dataService.getSimilarFeedItems(...)`.
typedef SimilarItemsLoader = Future<List<FeedItemModel>> Function(String feedItemId);

class MoreLikeThisCarousel extends StatefulWidget {
  final String feedItemId;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final EdgeInsets padding;
  final SimilarItemsLoader? loader;

  const MoreLikeThisCarousel({
    super.key,
    required this.feedItemId,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    this.padding = EdgeInsets.zero,
    this.loader,
  });

  @override
  State<MoreLikeThisCarousel> createState() => _MoreLikeThisCarouselState();
}

class _MoreLikeThisCarouselState extends State<MoreLikeThisCarousel> {
  late Future<List<FeedItemModel>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant MoreLikeThisCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.feedItemId != widget.feedItemId) {
      _future = _load();
    }
  }

  Future<List<FeedItemModel>> _load() {
    final loader = widget.loader;
    if (loader != null) return loader(widget.feedItemId);
    return context
        .read<AuthProvider>()
        .dataService
        .getSimilarFeedItems(widget.feedItemId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<FeedItemModel>>(
      future: _future,
      builder: (context, snap) {
        // Loading or empty / failed: render nothing. The carousel is a
        // discovery affordance — silence is better than a "no recs" pill.
        final items = snap.data;
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        if (items == null || items.isEmpty) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: widget.padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'More like this',
                style: GoogleFonts.playfairDisplay(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: widget.textColor,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 320,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, idx) =>
                      _SimilarCard(item: items[idx], isDark: widget.isDark),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SimilarCard extends StatelessWidget {
  final FeedItemModel item;
  final bool isDark;
  const _SimilarCard({required this.item, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final cardColor =
        isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF7F7F7);
    final textColor = isDark ? Colors.white : Colors.black;
    final subtle = isDark ? Colors.white70 : Colors.black54;

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          CupertinoPageRoute(
            builder: (_) => PostDetailPage(item: item),
          ),
        );
      },
      child: Container(
        width: 160,
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: item.imageMeta?.aspectRatio ?? 2 / 3,
              child: AppNetworkImage(
                url: item.imageUrl,
                meta: item.imageMeta,
                width: 160,
                fit: BoxFit.cover,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                      height: 1.25,
                    ),
                  ),
                  if (item.author.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    AuthorLink(
                      name: item.author,
                      authorId: item.authorId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: subtle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
