import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/services/smart_substitutions.dart';

void main() {
  group('SmartSubstitutions.compute', () {
    SmartSubstitution? sub({
      required String textAfter,
      required int offset,
      required String inserted,
    }) =>
        SmartSubstitutions.compute(
          textAfter: textAfter,
          insertOffset: offset,
          inserted: inserted,
        );

    test('opening double quote at start of doc', () {
      final r = sub(textAfter: '"', offset: 0, inserted: '"');
      expect(r, isNotNull);
      expect(r!.replacement, '“');
      expect(r.start, 0);
      expect(r.length, 1);
    });

    test('closing double quote after a letter', () {
      final r = sub(textAfter: 'hi"', offset: 2, inserted: '"');
      expect(r!.replacement, '”');
    });

    test('opening double quote after whitespace', () {
      final r = sub(textAfter: 'said "', offset: 5, inserted: '"');
      expect(r!.replacement, '“');
    });

    test('opening single quote at start', () {
      final r = sub(textAfter: "'", offset: 0, inserted: "'");
      expect(r!.replacement, '‘');
    });

    test("closing single quote (apostrophe) inside word", () {
      final r = sub(textAfter: "don't", offset: 3, inserted: "'");
      expect(r!.replacement, '’');
    });

    test('em dash from --', () {
      final r = sub(textAfter: 'wait--', offset: 5, inserted: '-');
      expect(r!.replacement, '—');
      expect(r.start, 4);
      expect(r.length, 2);
      expect(r.cursorAfter, 5);
    });

    test('ellipsis from ...', () {
      final r = sub(textAfter: 'wait...', offset: 6, inserted: '.');
      expect(r!.replacement, '…');
      expect(r.start, 4);
      expect(r.length, 3);
    });

    test('a single dot does not trigger ellipsis', () {
      final r = sub(textAfter: 'hi.', offset: 2, inserted: '.');
      expect(r, isNull);
    });

    test('two dots do not trigger ellipsis', () {
      final r = sub(textAfter: 'hi..', offset: 3, inserted: '.');
      expect(r, isNull);
    });

    test('a single hyphen does not trigger em dash', () {
      final r = sub(textAfter: 'a-', offset: 1, inserted: '-');
      expect(r, isNull);
    });

    test('multi-character insert (paste) is ignored', () {
      final r = sub(textAfter: 'hello "world"', offset: 6, inserted: '"world"');
      expect(r, isNull);
    });

    test('quote after open-paren is opening', () {
      final r = sub(textAfter: '("', offset: 1, inserted: '"');
      expect(r!.replacement, '“');
    });

    test('quote after period treated as closing (dialogue tag)', () {
      final r = sub(textAfter: 'said.”', offset: 5, inserted: '"');
      // Note: the textAfter must reflect the just-inserted straight quote;
      // here we simulate the user typing `"` after a period.
      final r2 = sub(textAfter: 'said."', offset: 5, inserted: '"');
      expect(r2!.replacement, '”');
      // r is just exercising the same code with a smart-quote trailing,
      // not asserted further.
      expect(r, isNotNull);
    });

    test('returns null for offset beyond text', () {
      final r = sub(textAfter: 'a', offset: 5, inserted: '"');
      expect(r, isNull);
    });
  });
}
