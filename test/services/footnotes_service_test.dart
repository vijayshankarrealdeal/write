import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/models/footnote_model.dart';
import 'package:inkspacex/services/footnotes_service.dart';
import 'package:inkspacex/ui/editor/footnote_embed_builder.dart';

void main() {
  group('FootnotesService.deltaFootnoteIds', () {
    test('returns ids in document order', () {
      final delta = [
        {'insert': 'Hello '},
        {
          'insert': {'footnote': 'fn-1'}
        },
        {'insert': ' world '},
        {
          'insert': {'footnote': 'fn-2'}
        },
        {'insert': '.\n'},
      ];
      expect(
        FootnotesService.deltaFootnoteIds(delta),
        equals(['fn-1', 'fn-2']),
      );
    });

    test('skips non-footnote embeds (images)', () {
      final delta = [
        {'insert': 'A '},
        {
          'insert': {'image': 'data:image/png;base64,abc'}
        },
        {'insert': ' B '},
        {
          'insert': {'footnote': 'fn-only'}
        },
        {'insert': '\n'},
      ];
      expect(
        FootnotesService.deltaFootnoteIds(delta),
        equals(['fn-only']),
      );
    });

    test('returns repeats for the same id (multi-cited footnote)', () {
      final delta = [
        {
          'insert': {'footnote': 'fn-x'}
        },
        {'insert': ' some text '},
        {
          'insert': {'footnote': 'fn-x'}
        },
        {'insert': '\n'},
      ];
      expect(
        FootnotesService.deltaFootnoteIds(delta),
        equals(['fn-x', 'fn-x']),
      );
    });
  });

  group('FootnotesService.idsFromContent', () {
    test('returns empty for empty content', () {
      expect(FootnotesService.idsFromContent(''), isEmpty);
    });

    test('returns empty for malformed JSON', () {
      expect(FootnotesService.idsFromContent('{not-a-delta'), isEmpty);
    });

    test('parses ids from a JSON-encoded delta string', () {
      const json = '[{"insert":"hi "},'
          '{"insert":{"footnote":"fn-a"}},'
          '{"insert":"\\n"}]';
      expect(FootnotesService.idsFromContent(json), equals(['fn-a']));
    });
  });

  group('FootnotesService.sortByDeltaOrder', () {
    test('reorders to match marker positions', () {
      final delta = [
        {
          'insert': {'footnote': 'fn-c'}
        },
        {'insert': ' xyz '},
        {
          'insert': {'footnote': 'fn-a'}
        },
        {'insert': '\n'},
      ];
      final unordered = [
        FootnoteModel(id: 'fn-a', text: 'A'),
        FootnoteModel(id: 'fn-b', text: 'B'),
        FootnoteModel(id: 'fn-c', text: 'C'),
      ];
      final result = FootnotesService.sortByDeltaOrder(unordered, delta);
      expect(result.map((f) => f.id).toList(), equals(['fn-c', 'fn-a', 'fn-b']));
    });

    test('orphans (footnotes with no marker in delta) go to the end', () {
      final delta = [
        {
          'insert': {'footnote': 'fn-2'}
        },
        {'insert': '\n'},
      ];
      final unordered = [
        FootnoteModel(id: 'fn-1', text: 'first'),
        FootnoteModel(id: 'fn-2', text: 'second'),
      ];
      final result = FootnotesService.sortByDeltaOrder(unordered, delta);
      expect(result.map((f) => f.id).toList(), equals(['fn-2', 'fn-1']));
    });

    test('drops embed ids that have no model', () {
      final delta = [
        {
          'insert': {'footnote': 'fn-ghost'}
        },
        {
          'insert': {'footnote': 'fn-real'}
        },
        {'insert': '\n'},
      ];
      final unordered = [FootnoteModel(id: 'fn-real', text: 'still here')];
      final result = FootnotesService.sortByDeltaOrder(unordered, delta);
      expect(result.map((f) => f.id).toList(), equals(['fn-real']));
    });

    test('repeated marker emits the model only once', () {
      final delta = [
        {
          'insert': {'footnote': 'fn-x'}
        },
        {'insert': ' lorem '},
        {
          'insert': {'footnote': 'fn-x'}
        },
        {'insert': '\n'},
      ];
      final unordered = [
        FootnoteModel(id: 'fn-x', text: 'cite'),
        FootnoteModel(id: 'fn-y', text: 'orphan'),
      ];
      final result = FootnotesService.sortByDeltaOrder(unordered, delta);
      // fn-x first (in-document), fn-y last (orphan).
      expect(result.map((f) => f.id).toList(), equals(['fn-x', 'fn-y']));
    });
  });

  group('FootnotesService.dropOrphans', () {
    test('keeps only footnotes with a live marker', () {
      final delta = [
        {
          'insert': {'footnote': 'fn-1'}
        },
        {'insert': '\n'},
      ];
      final all = [
        FootnoteModel(id: 'fn-1', text: 'kept'),
        FootnoteModel(id: 'fn-2', text: 'dropped'),
      ];
      final live = FootnotesService.dropOrphans(all, delta);
      expect(live.length, equals(1));
      expect(live.first.id, equals('fn-1'));
    });
  });

  group('FootnotesService.renderEndnotesDelta', () {
    test('emits heading + numbered paragraphs', () {
      final endnotes = FootnotesService.renderEndnotesDelta([
        FootnoteModel(id: 'a', text: 'first body'),
        FootnoteModel(id: 'b', text: 'second body'),
      ]);
      // Expect: \n + heading text + h3 attribute newline + (¹ first) + \n + (² second) + \n
      expect(endnotes, isNotEmpty);
      expect(endnotes.first['insert'], equals('\n'));
      expect(endnotes[1]['insert'], equals('Footnotes'));
      expect(endnotes[2]['insert'], equals('\n'));
      expect(endnotes[2]['attributes'], equals({'header': 3}));
      // ¹ (superscript 1) + space + first body
      expect(endnotes[3]['insert'], equals('¹ '));
      expect(endnotes[4]['insert'], equals('first body'));
    });

    test('returns empty for an empty list', () {
      expect(FootnotesService.renderEndnotesDelta([]), isEmpty);
    });
  });

  group('FootnotesService.renderEndnotesText', () {
    test('plain text shape matches the delta order', () {
      final out = FootnotesService.renderEndnotesText([
        FootnoteModel(id: 'a', text: 'one'),
        FootnoteModel(id: 'b', text: 'two'),
      ]);
      expect(out.contains('Footnotes'), isTrue);
      expect(out.contains('¹ one'), isTrue);
      expect(out.contains('² two'), isTrue);
    });

    test('returns empty for empty input', () {
      expect(FootnotesService.renderEndnotesText([]), equals(''));
    });
  });

  group('FootnotesService.newId', () {
    test('starts with the fn- prefix', () {
      final id = FootnotesService.newId(rand: math.Random(42));
      expect(id.startsWith('fn-'), isTrue);
    });

    test('returns distinct ids on consecutive calls', () {
      final a = FootnotesService.newId();
      final b = FootnotesService.newId();
      expect(a, isNot(equals(b)));
    });
  });

  group('toSuperscript', () {
    test('1 → ¹', () => expect(toSuperscript(1), '¹'));
    test('12 → ¹²', () => expect(toSuperscript(12), '¹²'));
    test('100 → ¹⁰⁰', () => expect(toSuperscript(100), '¹⁰⁰'));
    test('-3 → ⁻³', () => expect(toSuperscript(-3), '⁻³'));
  });

  group('FootnoteModel JSON round-trip', () {
    test('text + id survive a serialize/deserialize cycle', () {
      final f = FootnoteModel(id: 'fn-z', text: 'a real cite');
      final round = FootnoteModel.fromJson(f.toJson());
      expect(round.id, equals(f.id));
      expect(round.text, equals(f.text));
    });

    test('missing fields are tolerant', () {
      final round = FootnoteModel.fromJson({'id': 'fn-y'});
      expect(round.id, equals('fn-y'));
      expect(round.text, equals(''));
    });

    test('copyWith updates text and bumps updatedAt', () {
      final f = FootnoteModel(
        id: 'fn-q',
        text: 'old',
        createdAt: DateTime(2020),
        updatedAt: DateTime(2020),
      );
      final next = f.copyWith(text: 'new');
      expect(next.id, equals(f.id));
      expect(next.text, equals('new'));
      expect(next.updatedAt.isAfter(f.updatedAt), isTrue);
    });
  });
}
