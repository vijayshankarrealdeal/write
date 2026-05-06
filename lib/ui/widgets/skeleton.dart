import 'package:flutter/material.dart';

/// Lightweight shimmer placeholder — no extra package required.
///
/// A tinted box that animates a subtle highlight gradient across its
/// surface using a repeating [AnimationController]. Designed to be
/// composed (rows of skeletons that mimic the eventual content layout).
///
/// Use [Skeleton] when you can size the placeholder explicitly, and
/// [SkeletonContainer] for one-off custom shapes.
class Skeleton extends StatelessWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height = 12,
    this.widthFactor,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
  });

  final double? width;
  final double height;

  /// Set to constrain width to a fraction of the parent (0–1).
  final double? widthFactor;
  final BorderRadius? borderRadius;
  final BoxShape shape;

  @override
  Widget build(BuildContext context) {
    final box = SkeletonContainer(
      width: width ?? double.infinity,
      height: height,
      shape: shape,
      borderRadius: shape == BoxShape.rectangle
          ? (borderRadius ?? BorderRadius.circular(6))
          : null,
    );
    if (widthFactor != null) {
      return FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor,
        child: box,
      );
    }
    return box;
  }
}

class SkeletonContainer extends StatefulWidget {
  const SkeletonContainer({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
  });

  final double width;
  final double height;
  final BorderRadius? borderRadius;
  final BoxShape shape;

  @override
  State<SkeletonContainer> createState() => _SkeletonContainerState();
}

class _SkeletonContainerState extends State<SkeletonContainer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1400),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final highlight = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.04);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        // Map [0..1) progress to a gradient sweep from -1 to 2 so the
        // bright band fully exits the right edge before reappearing.
        final t = _controller.value;
        final dx = -1.0 + 3.0 * t;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: base,
            shape: widget.shape,
            borderRadius: widget.shape == BoxShape.rectangle
                ? (widget.borderRadius ?? BorderRadius.circular(6))
                : null,
            gradient: LinearGradient(
              begin: Alignment(dx - 0.4, 0),
              end: Alignment(dx + 0.4, 0),
              colors: [base, highlight, base],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
  }
}

/// A book-cover skeleton matching the proportions used in feed shelves.
class BookCardSkeleton extends StatelessWidget {
  const BookCardSkeleton({super.key, this.width = 130});

  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 3 / 4,
            child: SkeletonContainer(
              width: width,
              height: width * 4 / 3,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 10),
          const Skeleton(height: 12, widthFactor: 0.85),
          const SizedBox(height: 6),
          const Skeleton(height: 10, widthFactor: 0.55),
        ],
      ),
    );
  }
}

/// Horizontal shelf of book-cover skeletons used while the feed loads.
class BookShelfSkeleton extends StatelessWidget {
  const BookShelfSkeleton({
    super.key,
    this.itemCount = 6,
    this.cardWidth = 130,
    this.titleWidthFactor = 0.3,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final int itemCount;
  final double cardWidth;
  final double titleWidthFactor;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final shelfHeight = (cardWidth * 4 / 3) + 60;
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: padding,
            child: Skeleton(height: 18, widthFactor: titleWidthFactor),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: shelfHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: padding,
              itemCount: itemCount,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (_, _) => BookCardSkeleton(width: cardWidth),
            ),
          ),
        ],
      ),
    );
  }
}
