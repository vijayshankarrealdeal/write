import 'package:flutter/services.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:inkspacex/services/linguistic_focus_decoration.dart';
import 'package:inkspacex/services/linguistic_focus_service.dart';

QuillController _controllerFor(String text) {
  // Quill always appends a trailing `\n` to the doc body. Building from
  // the plain text plus an explicit terminator keeps the offset math
  // predictable across tests.
  final doc = Document.fromDelta(Delta()..insert('$text\n'));
  return QuillController(
    document: doc,
    selection: const TextSelection.collapsed(offset: 0),
  );
}

/// Helper: collect every (start, length) op that carries [attrKey] in
/// the controller's current document.
List<(int, int)> _attrRanges(QuillController c, String attrKey) {
  final ranges = <(int, int)>[];
  var offset = 0;
  for (final op in c.document.toDelta().toList()) {
    final attrs = op.attributes;
    final len = op.length ?? 0;
    if (op.data is String &&
        attrs != null &&
        attrs[attrKey] != null) {
      ranges.add((offset, len));
    }
    offset += len;
  }
  return ranges;
}

void main() {
  group('applyLinguisticFocus — span alignment', () {
    test('paints highlight on requested spans only', () {
      final c = _controllerFor('She ran quickly home.');
      // Highlight "quickly" — the adverb at offset 8, length 7.
      applyLinguisticFocus(
        c,
        activeClass: LinguisticClass.adverbs,
        highlightSpans: const [LinguisticSpan(start: 8, length: 7)],
      );
      final hi = _attrRanges(c, kLinguisticHighlightKey);
      expect(hi, contains((8, 7)));
    });

    test('paints dim layer on the complement of the highlight', () {
      final c = _controllerFor('She ran quickly home.');
      applyLinguisticFocus(
        c,
        activeClass: LinguisticClass.adverbs,
        highlightSpans: const [LinguisticSpan(start: 8, length: 7)],
      );
      final dim = _attrRanges(c, kLinguisticDimKey);
      // Dim should cover [0, 8) and [15, body) — two ranges.
      expect(dim, hasLength(2));
      expect(dim.first, (0, 8));
      expect(dim.last.$1, 15);
    });

    test('clears all marks when activeClass is null', () {
      final c = _controllerFor('Hello world');
      // First, paint something.
      applyLinguisticFocus(
        c,
        activeClass: LinguisticClass.dialogue,
        highlightSpans: const [LinguisticSpan(start: 0, length: 5)],
      );
      expect(_attrRanges(c, kLinguisticHighlightKey), isNotEmpty);

      // Then clear.
      applyLinguisticFocus(
        c,
        activeClass: null,
        highlightSpans: const [],
      );
      expect(_attrRanges(c, kLinguisticHighlightKey), isEmpty);
      expect(_attrRanges(c, kLinguisticDimKey), isEmpty);
    });

    test('clamps spans that overflow the doc body', () {
      final c = _controllerFor('hi');
      applyLinguisticFocus(
        c,
        activeClass: LinguisticClass.nouns,
        // Body is "hi" (length 2). Span end at 99 should be dropped.
        highlightSpans: const [LinguisticSpan(start: 0, length: 99)],
      );
      // No highlight applied — the only span overflowed.
      expect(_attrRanges(c, kLinguisticHighlightKey), isEmpty);
    });

    test('drops negative or zero-length spans', () {
      final c = _controllerFor('hello world');
      applyLinguisticFocus(
        c,
        activeClass: LinguisticClass.verbs,
        highlightSpans: const [
          LinguisticSpan(start: -1, length: 4),
          LinguisticSpan(start: 0, length: 0),
        ],
      );
      expect(_attrRanges(c, kLinguisticHighlightKey), isEmpty);
    });

    test('switching class swaps the highlight value cleanly', () {
      final c = _controllerFor('the quick brown fox');
      applyLinguisticFocus(
        c,
        activeClass: LinguisticClass.adverbs,
        highlightSpans: const [LinguisticSpan(start: 4, length: 5)],
      );
      // Now switch to a different class on a different span.
      applyLinguisticFocus(
        c,
        activeClass: LinguisticClass.adjectives,
        highlightSpans: const [LinguisticSpan(start: 10, length: 5)],
      );
      final hi = _attrRanges(c, kLinguisticHighlightKey);
      // Old adverb span gone; new adjective span present.
      expect(hi.any((r) => r.$1 == 4), isFalse);
      expect(hi.any((r) => r.$1 == 10), isTrue);
    });

    test('idempotent: re-applying the same overlay is a no-op', () {
      final c = _controllerFor('She ran fast.');
      applyLinguisticFocus(
        c,
        activeClass: LinguisticClass.adverbs,
        highlightSpans: const [LinguisticSpan(start: 8, length: 4)],
      );
      final firstDelta = c.document.toDelta().toJson();
      applyLinguisticFocus(
        c,
        activeClass: LinguisticClass.adverbs,
        highlightSpans: const [LinguisticSpan(start: 8, length: 4)],
      );
      final secondDelta = c.document.toDelta().toJson();
      expect(secondDelta, equals(firstDelta));
    });

    test('handles empty document without crashing', () {
      final doc = Document.fromDelta(Delta()..insert('\n'));
      final c = QuillController(
        document: doc,
        selection: const TextSelection.collapsed(offset: 0),
      );
      // No highlight, no crash.
      applyLinguisticFocus(
        c,
        activeClass: LinguisticClass.dialogue,
        highlightSpans: const [],
      );
      expect(_attrRanges(c, kLinguisticHighlightKey), isEmpty);
      expect(_attrRanges(c, kLinguisticDimKey), isEmpty);
    });
  });

  group('stripLinguisticAttrs', () {
    test('removes both highlight and dim from every op', () {
      final c = _controllerFor('hello world');
      applyLinguisticFocus(
        c,
        activeClass: LinguisticClass.nouns,
        highlightSpans: const [LinguisticSpan(start: 6, length: 5)],
      );
      final dirty = c.document.toDelta();
      final clean = stripLinguisticAttrs(dirty);
      for (final op in clean.toList()) {
        final attrs = op.attributes;
        if (attrs == null) continue;
        expect(attrs.containsKey(kLinguisticHighlightKey), isFalse);
        expect(attrs.containsKey(kLinguisticDimKey), isFalse);
      }
    });

    test('preserves non-linguistic attributes (e.g. bold)', () {
      // Insert with a bold attribute, then layer dim on top, then strip
      // — the bold must survive.
      final delta = Delta()
        ..insert('hello', {'bold': true})
        ..insert(' world\n');
      final clean = stripLinguisticAttrs(
        delta..retain(5, {kLinguisticDimKey: true}),
      );
      // First op is the original `insert('hello', {bold: true})` — still
      // carries bold, no dim.
      final firstOp = clean.toList().first;
      expect(firstOp.attributes?['bold'], true);
      expect(firstOp.attributes?.containsKey(kLinguisticDimKey), isFalse);
    });
  });

  group('Attribute factories', () {
    test('linguisticHighlightAttribute carries the class name', () {
      final attr = linguisticHighlightAttribute(className: 'adverbs');
      expect(attr.key, kLinguisticHighlightKey);
      expect(attr.value, 'adverbs');
    });

    test('linguisticDimAttribute toggles by `present`', () {
      expect(linguisticDimAttribute(present: true).value, true);
      expect(linguisticDimAttribute(present: false).value, isNull);
    });

    test('highlight color map covers every canonical class', () {
      for (final c in LinguisticClass.all) {
        expect(kLinguisticHighlightColors[c], isNotNull,
            reason: 'no colour for class $c');
      }
    });
  });
}
