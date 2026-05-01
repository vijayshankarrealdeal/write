import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

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
}

/// Loads a static dictionary asset and exposes spelling lookups + edit-
/// distance suggestions. Intentionally a singleton — the dictionary is
/// shared across the app so we don't pay the load cost more than once.
class SpellCheckService {
  SpellCheckService._();
  static final SpellCheckService instance = SpellCheckService._();

  static const String _assetPath = 'assets/dictionaries/en_us.txt';

  Set<String>? _dict;
  Future<void>? _loading;

  bool get isReady => _dict != null;

  /// Idempotent. Safe to call from multiple places concurrently — the
  /// future is memoised so the asset is parsed exactly once.
  Future<void> ensureLoaded() {
    if (_dict != null) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final raw = await rootBundle.loadString(_assetPath);
    final words = <String>{};
    for (final line in raw.split('\n')) {
      final w = line.trim();
      if (w.isEmpty) continue;
      words.add(w);
    }
    _dict = words;
  }

  /// True if [token] is in the dictionary (case-insensitive). Returns true
  /// for empty strings, single characters, and pure-numeric tokens so we
  /// don't flag those as misspellings.
  bool isKnown(String token) {
    if (_dict == null) return true;
    if (token.isEmpty) return true;
    if (token.length < 2) return true;
    if (RegExp(r'^[0-9]+$').hasMatch(token)) return true;
    return _dict!.contains(token.toLowerCase());
  }

  /// Scan [text] and return every misspelled word range. Skips numeric
  /// tokens, single characters, and any custom token containing digits.
  /// This is intentionally simple — heavy work is done in `checkAsync`
  /// so the editor stays responsive on long documents.
  List<Misspelling> check(String text) {
    if (_dict == null) return const [];
    if (text.isEmpty) return const [];
    final out = <Misspelling>[];
    // Match word characters + apostrophes inside words ("don't"). We trim
    // leading/trailing apostrophes when classifying so quotes don't get
    // flagged.
    final pattern = RegExp(r"[A-Za-z][A-Za-z']*[A-Za-z]|[A-Za-z]");
    for (final m in pattern.allMatches(text)) {
      final raw = m.group(0)!;
      // Strip leading/trailing apostrophes for lookup but keep position.
      final trimmed = raw.replaceAll(RegExp(r"^'+|'+$"), '');
      if (trimmed.length < 2) continue;
      if (isKnown(trimmed)) continue;
      // Possessive: "Bob's" → "Bob" lookup.
      if (trimmed.endsWith("'s") || trimmed.endsWith("'S")) {
        if (isKnown(trimmed.substring(0, trimmed.length - 2))) continue;
      }
      out.add(Misspelling(
        word: trimmed,
        start: m.start,
        length: raw.length,
      ));
    }
    return out;
  }

  /// Background-isolate variant. The dictionary is loaded on the main
  /// isolate; we copy the small `Set<String>` reference into the isolate
  /// payload so cross-isolate transfer stays cheap.
  Future<List<Misspelling>> checkAsync(String text) async {
    if (_dict == null) await ensureLoaded();
    final dict = _dict;
    if (dict == null || text.isEmpty) return const [];
    if (text.length < 2000) {
      // Don't bother with the isolate for short docs — IPC overhead
      // would be worse than the work.
      return check(text);
    }
    return compute(_runCheck, _CheckPayload(dict: dict, text: text));
  }

  /// Top suggestions for a misspelled word, ranked by Damerau-Levenshtein
  /// distance with a length-bias tiebreak. Empty if the dictionary isn't
  /// loaded yet. Capped at [max] entries; only words within distance 2
  /// are considered.
  List<String> suggest(String word, {int max = 5}) {
    final dict = _dict;
    if (dict == null) return const [];
    final lower = word.toLowerCase();
    if (lower.isEmpty) return const [];
    // Quick reject: if the dictionary contains the word, no suggestions.
    if (dict.contains(lower)) return const [];

    final candidates = <_Suggestion>[];
    final maxDist = lower.length <= 4 ? 1 : 2;
    final lo = lower.length - maxDist;
    final hi = lower.length + maxDist;
    final firstChar = lower[0];

    // Prefilter on length and (loosely) first letter — same first letter
    // OR a near letter. Most real-world typos preserve the head.
    for (final cand in dict) {
      if (cand.length < lo || cand.length > hi) continue;
      // Cheap head check: same first letter, or off-by-one head.
      if (cand[0] != firstChar) {
        if ((cand[0].codeUnitAt(0) - firstChar.codeUnitAt(0)).abs() > 1) {
          continue;
        }
      }
      final d = _damerauLevenshtein(lower, cand, maxDist);
      if (d <= maxDist) {
        candidates.add(_Suggestion(cand, d));
      }
    }
    candidates.sort((a, b) {
      if (a.distance != b.distance) return a.distance - b.distance;
      // Prefer same-length matches, then alphabetical for stability.
      final la = (a.word.length - lower.length).abs();
      final lb = (b.word.length - lower.length).abs();
      if (la != lb) return la - lb;
      return a.word.compareTo(b.word);
    });

    // Preserve casing: if the original was Capitalized or ALL CAPS, copy
    // that pattern onto each suggestion.
    final cased = candidates.take(max).map((c) => _matchCase(word, c.word));
    return cased.toList();
  }

  String _matchCase(String original, String suggestion) {
    if (original.isEmpty) return suggestion;
    if (original == original.toUpperCase()) return suggestion.toUpperCase();
    if (_isCapitalized(original)) {
      return suggestion[0].toUpperCase() + suggestion.substring(1);
    }
    return suggestion;
  }

  bool _isCapitalized(String s) {
    if (s.isEmpty) return false;
    return s[0] == s[0].toUpperCase() &&
        s.substring(1) == s.substring(1).toLowerCase();
  }
}

class _Suggestion {
  final String word;
  final int distance;
  const _Suggestion(this.word, this.distance);
}

class _CheckPayload {
  final Set<String> dict;
  final String text;
  const _CheckPayload({required this.dict, required this.text});
}

List<Misspelling> _runCheck(_CheckPayload payload) {
  final out = <Misspelling>[];
  final pattern = RegExp(r"[A-Za-z][A-Za-z']*[A-Za-z]|[A-Za-z]");
  for (final m in pattern.allMatches(payload.text)) {
    final raw = m.group(0)!;
    final trimmed = raw.replaceAll(RegExp(r"^'+|'+$"), '');
    if (trimmed.length < 2) continue;
    final lower = trimmed.toLowerCase();
    if (RegExp(r'^[0-9]+$').hasMatch(lower)) continue;
    if (payload.dict.contains(lower)) continue;
    if (lower.endsWith("'s") &&
        payload.dict.contains(lower.substring(0, lower.length - 2))) {
      continue;
    }
    out.add(Misspelling(word: trimmed, start: m.start, length: raw.length));
  }
  return out;
}

/// Damerau-Levenshtein with an early-exit when the running minimum already
/// exceeds [maxDist]. Saves a lot of work when most candidates are far away.
int _damerauLevenshtein(String a, String b, int maxDist) {
  final n = a.length;
  final m = b.length;
  if ((n - m).abs() > maxDist) return maxDist + 1;
  // Two-row DP plus a previous-previous row for transposition.
  var prev2 = List<int>.filled(m + 1, 0);
  var prev = List<int>.generate(m + 1, (i) => i);
  var curr = List<int>.filled(m + 1, 0);
  for (var i = 1; i <= n; i++) {
    curr[0] = i;
    var rowMin = i;
    for (var j = 1; j <= m; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var v = _min3(
        curr[j - 1] + 1,
        prev[j] + 1,
        prev[j - 1] + cost,
      );
      if (i > 1 &&
          j > 1 &&
          a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) &&
          a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1)) {
        v = v < prev2[j - 2] + cost ? v : prev2[j - 2] + cost;
      }
      curr[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > maxDist) return maxDist + 1;
    final tmp = prev2;
    prev2 = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[m];
}

int _min3(int a, int b, int c) {
  final ab = a < b ? a : b;
  return ab < c ? ab : c;
}
