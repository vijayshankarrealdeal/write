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

  /// Reconstruct an [ImageMeta] from a single URL whose `#`-fragment carries
  /// pipeline metadata (`bh`, `dc`, `iw`, `ih`, `vs`).
  ///
  /// Used for embed-only contexts (Quill inline images, canvas elements) that
  /// persist a single URL string. The fragment is appended by the backend
  /// when it returns the URL on upload, and we keep it through edits via
  /// `_ImageTransform.serialize()` so it survives republishing.
  ///
  /// Returns `null` if the fragment doesn't carry meta keys (legacy URLs,
  /// data URIs, or anything we can't make sense of).
  static ImageMeta? fromInlineUrl(String url) {
    if (url.startsWith('data:')) return null;
    final hashIdx = url.lastIndexOf('#');
    if (hashIdx == -1) return null;
    final urlPart = url.substring(0, hashIdx);
    final frag = url.substring(hashIdx + 1);
    String? bh;
    String dcHex = '';
    int iw = 0, ih = 0;
    String scope = 'default';
    for (final part in frag.split('&')) {
      final eq = part.indexOf('=');
      if (eq == -1) continue;
      final k = part.substring(0, eq);
      final v = part.substring(eq + 1);
      switch (k) {
        case 'bh':
          bh = v;
        case 'dc':
          dcHex = v;
        case 'iw':
          iw = int.tryParse(v) ?? 0;
        case 'ih':
          ih = int.tryParse(v) ?? 0;
        case 'vs':
          scope = v;
      }
    }
    if (bh == null || iw == 0 || ih == 0) return null;
    // The URL portion is `<base>/<key>.<fmt>`. Strip the trailing key.fmt
    // segment to recover the base path that variants live under.
    final lastSlash = urlPart.lastIndexOf('/');
    if (lastSlash < 0) return null;
    final base = urlPart.substring(0, lastSlash);
    final variants = _scopeVariants(scope, iw, ih);
    return ImageMeta(
      baseUrl: base,
      width: iw,
      height: ih,
      blurhash: bh,
      color: dcHex.isEmpty ? '#cccccc' : '#$dcHex',
      formats: const ['webp'],
      variants: variants,
    );
  }

  /// Mirror of the backend's per-scope variant tables. The pipeline always
  /// emits these key/edge pairs, so given the original dimensions we can
  /// compute each variant's actual dimensions without round-tripping them
  /// through the URL fragment (which would bloat every embed).
  static Map<String, _VariantSize> _scopeVariants(
    String scope,
    int iw,
    int ih,
  ) {
    const editor = [
      ['small', 480],
      ['medium', 960],
      ['large', 1600],
      ['original', 2400],
    ];
    const avatar = [
      ['thumb', 96],
      ['small', 256],
      ['medium', 512],
    ];
    const def = [
      ['thumb', 160],
      ['small', 400],
      ['medium', 800],
      ['large', 1600],
      ['original', 2400],
    ];
    final table = switch (scope) {
      'editor' => editor,
      'avatar' => avatar,
      _ => def,
    };
    final out = <String, _VariantSize>{};
    final longest = iw >= ih ? iw : ih;
    for (final entry in table) {
      final key = entry[0] as String;
      final maxEdge = entry[1] as int;
      // Match the backend's behaviour: if the longest edge is already
      // smaller than the target, keep the original dims (no upscale).
      if (longest <= maxEdge) {
        out[key] = _VariantSize(iw, ih);
      } else {
        final scale = maxEdge / longest;
        out[key] = _VariantSize(
          (iw * scale).round().clamp(1, iw),
          (ih * scale).round().clamp(1, ih),
        );
      }
    }
    return out;
  }

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
