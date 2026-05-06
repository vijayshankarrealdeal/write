import 'package:shared_preferences/shared_preferences.dart';

/// Replacement instruction returned by [SmartSubstitutions.compute].
class SmartSubstitution {
  const SmartSubstitution({
    required this.start,
    required this.length,
    required this.replacement,
  });

  final int start;
  final int length;
  final String replacement;

  int get cursorAfter => start + replacement.length;
}

/// Pure transformer + persisted toggle for Scrivener-style autocorrect:
/// straight quotes → curly, `--` → em dash, `...` → ellipsis.
///
/// `compute` is side-effect-free so it can be unit tested without a
/// QuillController; the editor wires it into the document-changes
/// stream and applies the result via [QuillController.replaceText].
class SmartSubstitutions {
  static const _prefsKey = 'smart_punctuation_enabled_v1';

  static Future<bool> loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsKey) ?? true;
  }

  static Future<void> saveEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, value);
  }

  /// Returns the substitution to apply for a single-character insertion,
  /// or null when no rule fires.
  ///
  /// `textAfter` is the document plain-text *after* [inserted] landed at
  /// [insertOffset]. The caller is responsible for ensuring [inserted]
  /// is a single user-typed character (paste, IME bursts, and
  /// programmatic edits should be filtered out at the source).
  static SmartSubstitution? compute({
    required String textAfter,
    required int insertOffset,
    required String inserted,
  }) {
    if (inserted.length != 1) return null;
    if (insertOffset < 0 || insertOffset >= textAfter.length) return null;

    final char = inserted;
    final prev = insertOffset > 0 ? textAfter[insertOffset - 1] : '';
    final prevPrev = insertOffset > 1 ? textAfter[insertOffset - 2] : '';

    if (char == '"') {
      return SmartSubstitution(
        start: insertOffset,
        length: 1,
        replacement: _isOpeningContext(prev) ? '“' : '”',
      );
    }

    if (char == "'") {
      return SmartSubstitution(
        start: insertOffset,
        length: 1,
        replacement: _isOpeningContext(prev) ? '‘' : '’',
      );
    }

    if (char == '-' && prev == '-') {
      return SmartSubstitution(
        start: insertOffset - 1,
        length: 2,
        replacement: '—',
      );
    }

    if (char == '.' && prev == '.' && prevPrev == '.') {
      return SmartSubstitution(
        start: insertOffset - 2,
        length: 3,
        replacement: '…',
      );
    }

    return null;
  }

  /// True if [prev] is the kind of character that should make the next
  /// quote an opening quote: start of doc, whitespace, or an opening
  /// bracket. Punctuation that closes a clause (`.`, `,`, `?`, `!`, `:`,
  /// `;`) is treated as closing context so dialogue tags work right.
  static bool _isOpeningContext(String prev) {
    if (prev.isEmpty) return true;
    return RegExp(r'[\s\(\[\{<—–]').hasMatch(prev);
  }
}
