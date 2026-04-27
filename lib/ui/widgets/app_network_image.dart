import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blurhash/flutter_blurhash.dart';

import '../../models/image_meta.dart';
import '../../services/image_cache_manager.dart';

/// One widget for every network image in the app.
///
/// Reasons this exists instead of `CachedNetworkImage` directly:
///   * It picks the smallest backend variant that fits the rendered size,
///     so we stop pulling 1600px hero images into 64px avatars.
///   * It paints a blurhash + dominant color placeholder immediately, so
///     the layout never flashes empty grey while the network call resolves.
///   * It works with legacy URLs that have no [ImageMeta] — falls back to
///     a simple cached image, no placeholder.
///
/// The caller passes the rendered width in CSS pixels via [width]. If the
/// render is laid out with a fluid box (no fixed width), pass [width] equal
/// to the typical bound — selecting one size larger than needed is harmless.
class AppNetworkImage extends StatelessWidget {
  final String? url;          // legacy single-URL field, used when meta missing
  final ImageMeta? meta;      // preferred — server-provided metadata
  final double? width;        // CSS pixels; used to pick the variant
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final Widget? errorWidget;
  final Color? placeholderColor; // overrides the dominant color from meta
  final FilterQuality filterQuality;

  const AppNetworkImage({
    super.key,
    this.url,
    this.meta,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.errorWidget,
    this.placeholderColor,
    this.filterQuality = FilterQuality.medium,
  });

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    final targetUrl = _resolveUrl(dpr);

    if (targetUrl == null || targetUrl.isEmpty) {
      return _wrap(_buildPlaceholder(context, isError: false));
    }

    final image = CachedNetworkImage(
      imageUrl: targetUrl,
      width: width,
      height: height,
      fit: fit,
      filterQuality: filterQuality,
      // Memory-cache at the rendered pixel size so the engine doesn't decode
      // a 1600px image into a 200px slot and burn 12x the memory needed.
      memCacheWidth: width != null ? (width! * dpr).round() : null,
      memCacheHeight: height != null ? (height! * dpr).round() : null,
      cacheManager: AppImageCacheManager(),
      placeholder: (ctx, _) => _buildPlaceholder(ctx, isError: false),
      errorWidget: (ctx, _, __) => errorWidget ?? _buildPlaceholder(ctx, isError: true),
      fadeInDuration: const Duration(milliseconds: 180),
    );
    return _wrap(image);
  }

  String? _resolveUrl(double dpr) {
    if (meta != null) {
      if (width != null) {
        return meta!.urlForWidth(width!, devicePixelRatio: dpr);
      }
      return meta!.largestUrl;
    }
    return url;
  }

  Widget _wrap(Widget child) {
    if (borderRadius == null) return child;
    return ClipRRect(borderRadius: borderRadius!, child: child);
  }

  Widget _buildPlaceholder(BuildContext context, {required bool isError}) {
    final fallbackColor = placeholderColor ??
        _hexToColor(meta?.color) ??
        Theme.of(context).colorScheme.surfaceContainerHighest;

    Widget body;
    if (!isError && meta != null && meta!.blurhash.isNotEmpty) {
      body = BlurHash(
        hash: meta!.blurhash,
        imageFit: fit,
        color: fallbackColor,
      );
    } else {
      body = Container(
        color: fallbackColor,
        alignment: Alignment.center,
        child: isError
            ? Icon(
                Icons.broken_image_outlined,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                size: 24,
              )
            : null,
      );
    }
    return SizedBox(width: width, height: height, child: body);
  }

  /// Warm the image cache for an upcoming render. Call from list/feed scroll
  /// handlers with the next few items so the user doesn't see the blurhash
  /// → real-image swap when they actually reach those tiles.
  ///
  /// Picks the smallest variant that fits [width] at the device's DPR — same
  /// logic as live rendering, so the cached entry is the exact one the
  /// widget will request later. Best-effort: errors are swallowed.
  static Future<void> precache(
    BuildContext context, {
    String? url,
    ImageMeta? meta,
    required double width,
  }) async {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    String? target;
    if (meta != null) {
      target = meta.urlForWidth(width, devicePixelRatio: dpr);
    } else {
      target = url;
    }
    if (target == null || target.isEmpty) return;
    try {
      await precacheImage(
        CachedNetworkImageProvider(
          target,
          cacheManager: AppImageCacheManager(),
        ),
        context,
      );
    } catch (_) {
      // Network hiccups during prefetch shouldn't bubble up — the live
      // render will retry and surface the error itself if it persists.
    }
  }

  static Color? _hexToColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final h = hex.replaceFirst('#', '');
    if (h.length != 6) return null;
    final v = int.tryParse(h, radix: 16);
    if (v == null) return null;
    return Color(0xFF000000 | v);
  }
}
