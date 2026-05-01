import 'dart:async';

import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/app_log.dart' show log;

/// One detected misspelling and its plain-text offset range. The provider
/// converts these to whatever the Quill editor needs (selection ranges,
/// scroll-to actions, replace operations).
class Misspelling {
  final String word;
  final int start;
  final int length;

  const Misspelling({
    required this.word,
    required this.start,
    required this.length,
  });

  int get end => start + length;

  factory Misspelling.fromJson(Map<String, dynamic> j) => Misspelling(
        word: j['word'] as String,
        start: (j['start'] as num).toInt(),
        length: (j['length'] as num).toInt(),
      );
}

/// Thin client over `/api/spellcheck`. The dictionary lives on the backend
/// so we can grow or swap it without shipping a new app build. All checks
/// hit the network; offline scans simply return empty (the provider
/// surfaces "0 issues" rather than guessing locally).
class SpellCheckService {
  SpellCheckService(this._api);

  final ApiClient _api;
  // Per-session suggestion cache. The dictionary is stable enough during
  // a session that re-fetching suggestions for the same word is wasted
  // network — the inline correction bar fires a request every time the
  // caret lands on an underline, which gets old fast on a doc with the
  // same misspelling repeated. Capped so a long session can't grow
  // unbounded.
  static const int _suggestCacheLimit = 256;
  final Map<String, List<String>> _suggestCache = {};

  Future<List<Misspelling>> check(
    String text, {
    Iterable<String> ignored = const [],
  }) async {
    if (text.isEmpty) return const [];
    try {
      final res = await _api.post('/api/spellcheck/check', data: {
        'text': text,
        'ignored': ignored.toList(),
      });
      final data = res.data;
      if (data is! Map) return const [];
      final list = data['issues'];
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((m) => Misspelling.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } on ApiException catch (e) {
      log.w('spellcheck.check failed: ${e.message}');
      return const [];
    } catch (e) {
      log.w('spellcheck.check error: $e');
      return const [];
    }
  }

  Future<List<String>> suggest(String word, {int max = 5}) async {
    if (word.isEmpty) return const [];
    final cacheKey = '${word.toLowerCase()}|$max';
    final cached = _suggestCache[cacheKey];
    if (cached != null) return cached;
    try {
      final res = await _api.post('/api/spellcheck/suggest', data: {
        'word': word,
        'max': max,
      });
      final data = res.data;
      if (data is! Map) return const [];
      final list = data['suggestions'];
      if (list is! List) return const [];
      final out = list.whereType<String>().toList(growable: false);
      // Cheap LRU-ish bound: drop the oldest entry once over the cap.
      // Real LRU would need a linked map; for ~256 words it's overkill.
      if (_suggestCache.length >= _suggestCacheLimit) {
        _suggestCache.remove(_suggestCache.keys.first);
      }
      _suggestCache[cacheKey] = out;
      return out;
    } on ApiException catch (e) {
      log.w('spellcheck.suggest failed: ${e.message}');
      return const [];
    } catch (e) {
      log.w('spellcheck.suggest error: $e');
      return const [];
    }
  }
}
