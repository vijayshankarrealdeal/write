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
    try {
      final res = await _api.post('/api/spellcheck/suggest', data: {
        'word': word,
        'max': max,
      });
      final data = res.data;
      if (data is! Map) return const [];
      final list = data['suggestions'];
      if (list is! List) return const [];
      return list.whereType<String>().toList();
    } on ApiException catch (e) {
      log.w('spellcheck.suggest failed: ${e.message}');
      return const [];
    } catch (e) {
      log.w('spellcheck.suggest error: $e');
      return const [];
    }
  }
}
