import 'dart:async';

import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/app_log.dart' show log;

/// One detected span (start + length, both in plain-text codepoint
/// indices into [Document.toPlainText()]). Same shape as
/// [Misspelling] in the spell-check service so the editor's overlay
/// pipeline can borrow the existing offset-walking helpers.
class LinguisticSpan {
  const LinguisticSpan({required this.start, required this.length});

  final int start;
  final int length;

  int get end => start + length;

  factory LinguisticSpan.fromJson(Map<String, dynamic> j) => LinguisticSpan(
        start: (j['start'] as num).toInt(),
        length: (j['length'] as num).toInt(),
      );

  @override
  bool operator ==(Object other) =>
      other is LinguisticSpan &&
      other.start == start &&
      other.length == length;

  @override
  int get hashCode => Object.hash(start, length);
}

/// One scan result — spans bucketed by linguistic class. The five
/// classes are the same set the toggle UI exposes; we always hand
/// back all five (with empty lists for classes the request didn't
/// ask for) so the consumer can swap classes without re-fetching.
class LinguisticTagResult {
  const LinguisticTagResult({
    required this.dialogue,
    required this.adverbs,
    required this.adjectives,
    required this.verbs,
    required this.nouns,
    required this.posAvailable,
  });

  final List<LinguisticSpan> dialogue;
  final List<LinguisticSpan> adverbs;
  final List<LinguisticSpan> adjectives;
  final List<LinguisticSpan> verbs;
  final List<LinguisticSpan> nouns;

  /// False when the backend's spaCy model isn't loaded — only
  /// dialogue spans are reliable. The editor surfaces a hint instead
  /// of pretending the doc has zero adverbs etc.
  final bool posAvailable;

  static const empty = LinguisticTagResult(
    dialogue: [],
    adverbs: [],
    adjectives: [],
    verbs: [],
    nouns: [],
    posAvailable: true,
  );

  /// Pull the spans for [className], one of the five canonical names.
  /// Returns an empty list for an unknown class so the caller doesn't
  /// have to guard on every lookup.
  List<LinguisticSpan> spansFor(String className) {
    switch (className) {
      case LinguisticClass.dialogue:
        return dialogue;
      case LinguisticClass.adverbs:
        return adverbs;
      case LinguisticClass.adjectives:
        return adjectives;
      case LinguisticClass.verbs:
        return verbs;
      case LinguisticClass.nouns:
        return nouns;
      default:
        return const [];
    }
  }

  factory LinguisticTagResult.fromJson(Map<String, dynamic> j) {
    List<LinguisticSpan> parse(dynamic raw) {
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((m) => LinguisticSpan.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    }

    return LinguisticTagResult(
      dialogue: parse(j['dialogue']),
      adverbs: parse(j['adverbs']),
      adjectives: parse(j['adjectives']),
      verbs: parse(j['verbs']),
      nouns: parse(j['nouns']),
      posAvailable: (j['pos_available'] as bool?) ?? true,
    );
  }
}

/// Canonical class names — kept as a separate type so the toggle UI
/// and the API client share a single source of truth and a typo
/// becomes a compile error rather than an empty highlight.
class LinguisticClass {
  const LinguisticClass._();

  static const String dialogue = 'dialogue';
  static const String adverbs = 'adverbs';
  static const String adjectives = 'adjectives';
  static const String verbs = 'verbs';
  static const String nouns = 'nouns';

  static const List<String> all = [
    dialogue,
    adverbs,
    adjectives,
    verbs,
    nouns,
  ];

  /// Capitalised label used in the toggle UI.
  static String label(String className) {
    switch (className) {
      case dialogue:
        return 'Dialogue';
      case adverbs:
        return 'Adverbs';
      case adjectives:
        return 'Adjectives';
      case verbs:
        return 'Verbs';
      case nouns:
        return 'Nouns';
      default:
        return className;
    }
  }
}

/// Thin client over `/api/linguistic/tag`. Backend hosts spaCy so
/// the model and any future tweaks ship without an app build. All
/// calls are best-effort — a network failure returns
/// [LinguisticTagResult.empty] so the overlay just shows nothing
/// rather than the whole editor blowing up.
class LinguisticFocusService {
  LinguisticFocusService(this._api);

  final ApiClient _api;

  Future<LinguisticTagResult> tag(
    String text, {
    Iterable<String> classes = LinguisticClass.all,
  }) async {
    if (text.isEmpty) return LinguisticTagResult.empty;
    try {
      final res = await _api.post(
        '/api/linguistic/tag',
        data: {
          'text': text,
          'classes': classes.toList(),
        },
        // Best-effort — a 5xx during a backend restart should not
        // bubble red errors. The provider returns empty spans and
        // the overlay shows nothing rather than crashing.
        silent: true,
      );
      final data = res.data;
      if (data is! Map) return LinguisticTagResult.empty;
      return LinguisticTagResult.fromJson(Map<String, dynamic>.from(data));
    } on ApiException catch (e) {
      log.w('linguistic.tag failed: ${e.message}');
      return LinguisticTagResult.empty;
    } catch (e) {
      log.w('linguistic.tag error: $e');
      return LinguisticTagResult.empty;
    }
  }
}
