import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/services/linguistic_focus_service.dart';

void main() {
  group('LinguisticTagResult.fromJson', () {
    test('parses all five class buckets and pos_available flag', () {
      final r = LinguisticTagResult.fromJson({
        'dialogue': [
          {'start': 0, 'length': 5},
          {'start': 10, 'length': 7},
        ],
        'adverbs': [
          {'start': 6, 'length': 7},
        ],
        'adjectives': const [],
        'verbs': [
          {'start': 14, 'length': 3},
        ],
        'nouns': [
          {'start': 0, 'length': 3},
        ],
        'pos_available': true,
      });
      expect(r.dialogue, hasLength(2));
      expect(r.dialogue.first, const LinguisticSpan(start: 0, length: 5));
      expect(r.adverbs.first.start, 6);
      expect(r.adverbs.first.length, 7);
      expect(r.adjectives, isEmpty);
      expect(r.verbs.single.start, 14);
      expect(r.nouns.single.length, 3);
      expect(r.posAvailable, isTrue);
    });

    test('treats missing keys as empty lists', () {
      final r = LinguisticTagResult.fromJson({});
      expect(r.dialogue, isEmpty);
      expect(r.adverbs, isEmpty);
      expect(r.adjectives, isEmpty);
      expect(r.verbs, isEmpty);
      expect(r.nouns, isEmpty);
      // Default — backend always sends true when absent (rare in practice).
      expect(r.posAvailable, isTrue);
    });

    test('treats malformed bucket as empty list, not crash', () {
      final r = LinguisticTagResult.fromJson({
        'dialogue': 'not a list',
        'adverbs': 42,
        'pos_available': false,
      });
      expect(r.dialogue, isEmpty);
      expect(r.adverbs, isEmpty);
      expect(r.posAvailable, isFalse);
    });

    test('honours pos_available=false (degraded backend)', () {
      final r = LinguisticTagResult.fromJson({
        'dialogue': [
          {'start': 0, 'length': 3},
        ],
        'pos_available': false,
      });
      expect(r.dialogue, isNotEmpty);
      expect(r.posAvailable, isFalse);
    });
  });

  group('LinguisticTagResult.spansFor', () {
    test('returns the right bucket per class name', () {
      const r = LinguisticTagResult(
        dialogue: [LinguisticSpan(start: 0, length: 1)],
        adverbs: [LinguisticSpan(start: 1, length: 1)],
        adjectives: [LinguisticSpan(start: 2, length: 1)],
        verbs: [LinguisticSpan(start: 3, length: 1)],
        nouns: [LinguisticSpan(start: 4, length: 1)],
        posAvailable: true,
      );
      expect(r.spansFor(LinguisticClass.dialogue).single.start, 0);
      expect(r.spansFor(LinguisticClass.adverbs).single.start, 1);
      expect(r.spansFor(LinguisticClass.adjectives).single.start, 2);
      expect(r.spansFor(LinguisticClass.verbs).single.start, 3);
      expect(r.spansFor(LinguisticClass.nouns).single.start, 4);
    });

    test('unknown class returns empty list (no throw)', () {
      const r = LinguisticTagResult(
        dialogue: [LinguisticSpan(start: 0, length: 1)],
        adverbs: [],
        adjectives: [],
        verbs: [],
        nouns: [],
        posAvailable: true,
      );
      expect(r.spansFor('banana'), isEmpty);
    });
  });

  group('LinguisticClass', () {
    test('all contains exactly the five canonical names', () {
      expect(LinguisticClass.all, [
        'dialogue',
        'adverbs',
        'adjectives',
        'verbs',
        'nouns',
      ]);
    });

    test('label() capitalises canonical names', () {
      expect(LinguisticClass.label('dialogue'), 'Dialogue');
      expect(LinguisticClass.label('adverbs'), 'Adverbs');
      expect(LinguisticClass.label('adjectives'), 'Adjectives');
      expect(LinguisticClass.label('verbs'), 'Verbs');
      expect(LinguisticClass.label('nouns'), 'Nouns');
    });

    test('label() falls through unknown names verbatim', () {
      expect(LinguisticClass.label('???'), '???');
    });
  });

  group('LinguisticSpan equality', () {
    test('equal spans compare equal and share a hashCode', () {
      const a = LinguisticSpan(start: 1, length: 2);
      const b = LinguisticSpan(start: 1, length: 2);
      const c = LinguisticSpan(start: 1, length: 3);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('end is start + length', () {
      const s = LinguisticSpan(start: 5, length: 7);
      expect(s.end, 12);
    });
  });
}
