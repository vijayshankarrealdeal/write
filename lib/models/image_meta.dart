/// Metadata sidecar for every backend-processed image.
///
/// The backend emits multiple size variants and embeds the dimensions, a
/// blurhash placeholder, and a dominant color. Carrying that metadata around
/// lets the client (a) reserve layout space before the image arrives, (b)
/// paint a coloured/blurhash placeholder instantly, and (c) request the
/// smallest variant that fits the rendered area instead of always pulling
/// the largest file.
class ImageMeta {
  final String baseUrl; // e.g. https://cdn.../users/<id>/profile/avatar
  final int width;
  final int height;
  final String blurhash;
  final String color; // "#rrggbb"
  final List<String> formats; // ["webp", "jpeg"]
  final Map<String, _VariantSize> variants; // key -> {w, h}

  const ImageMeta({
    required this.baseUrl,
    required this.width,
    required this.height,
    required this.blurhash,
    required this.color,
    required this.formats,
    required this.variants,
  });

  static ImageMeta? tryFromJson(dynamic json) {
    if (json is! Map) return null;
    final base = json['base_url'] ?? json['baseUrl'];
    if (base is! String || base.isEmpty) return null;
    final variantsJson = json['variants'];
    final formats = (json['formats'] as List?)?.cast<String>() ?? const ['jpeg'];
    final v = <String, _VariantSize>{};
    if (variantsJson is Map) {
      variantsJson.forEach((key, value) {
        if (value is Map) {
          final w = (value['w'] as num?)?.toInt() ?? 0;
          final h = (value['h'] as num?)?.toInt() ?? 0;
          v[key.toString()] = _VariantSize(w, h);
        }
      });
    }
    return ImageMeta(
      baseUrl: base,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      blurhash: (json['blurhash'] as String?) ?? '',
      color: (json['color'] as String?) ?? '#cccccc',
      formats: formats,
      variants: v,
    );
  }

  Map<String, dynamic> toJson() => {
        'base_url': baseUrl,
        'width': width,
        'height': height,
        'blurhash': blurhash,
        'color': color,
        'formats': formats,
        'variants': {
          for (final e in variants.entries)
            e.key: {'w': e.value.w, 'h': e.value.h},
        },
      };

  /// Returns the best-fit URL for a target rendered width in CSS pixels and
  /// the device pixel ratio. Picks the smallest variant whose pixel width
  /// is >= targetWidth * dpr.
  String urlForWidth(double targetWidth, {double devicePixelRatio = 2.0}) {
    final wantedPx = (targetWidth * devicePixelRatio).round();
    final fmt = formats.contains('webp') ? 'webp' : formats.first;
    final keys = variants.keys.toList()
      ..sort((a, b) => variants[a]!.w.compareTo(variants[b]!.w));
    for (final k in keys) {
      if (variants[k]!.w >= wantedPx) return '$baseUrl/$k.$fmt';
    }
    final largest = keys.isNotEmpty ? keys.last : null;
    return largest != null ? '$baseUrl/$largest.$fmt' : baseUrl;
  }

  /// Convenience: the largest variant URL, used when we want the full-res
  /// image (zoom views, hero crops, downloads).
  String get largestUrl {
    if (variants.isEmpty) return baseUrl;
    final fmt = formats.contains('webp') ? 'webp' : formats.first;
    final largest = variants.entries
        .reduce((a, b) => a.value.w >= b.value.w ? a : b)
        .key;
    return '$baseUrl/$largest.$fmt';
  }

  double get aspectRatio => height == 0 ? 1.0 : width / height;
}

class _VariantSize {
  final int w;
  final int h;
  const _VariantSize(this.w, this.h);
}
