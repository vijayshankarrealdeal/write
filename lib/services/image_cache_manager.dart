/// Shared `CacheManager` for every `cached_network_image` request.
///
/// `flutter_cache_manager` retains files keyed by URL with a stale
/// period + maximum object count. Configuring it explicitly (instead
/// of relying on the package default) lets us tune the window the user
/// actually sees and gives us a single hook to clear from the
/// settings page.
///
/// Knobs:
///   * 30-day stale period — matches the typical "I came back to a
///     book I read last month" hit pattern.
///   * 400 cache objects — at ~500 KB per cover-sized WebP variant
///     (the most common size), 400 entries lands around 200 MB on
///     disk. The `flutter_cache_manager` API exposes object count,
///     not bytes; if telemetry shows we need a true byte cap we
///     swap this for a custom store. p2.md §4.4 calls this out.
library;

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class AppImageCacheManager extends CacheManager {
  static const String key = 'app_image_cache_v1';

  static final AppImageCacheManager _instance = AppImageCacheManager._();
  factory AppImageCacheManager() => _instance;

  AppImageCacheManager._()
      : super(
          Config(
            key,
            stalePeriod: const Duration(days: 30),
            maxNrOfCacheObjects: 400,
          ),
        );
}
