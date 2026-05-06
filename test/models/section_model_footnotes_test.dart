import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/models/footnote_model.dart';
import 'package:inkspacex/models/section_model.dart';

void main() {
  group('SectionModel footnote serialization', () {
    test('toJson includes footnotes as a list of maps', () {
      final s = SectionModel(
        id: 's-1',
        title: 'Chapter 1',
        content: '',
        sectionColor: Colors.blueAccent,
        footnotes: [
          FootnoteModel(id: 'fn-a', text: 'cite a'),
          FootnoteModel(id: 'fn-b', text: 'cite b'),
        ],
      );
      final json = s.toJson();
      expect(json['footnotes'], isA<List>());
      final list = json['footnotes'] as List;
      expect(list.length, equals(2));
      expect((list.first as Map)['id'], equals('fn-a'));
      expect((list.first as Map)['text'], equals('cite a'));
    });

    test('fromJson restores the footnote list and order', () {
      final s = SectionModel(
        id: 's-2',
        title: 'Chapter 2',
        content: '',
        sectionColor: Colors.amber,
        footnotes: [
          FootnoteModel(id: 'fn-1', text: 'first'),
          FootnoteModel(id: 'fn-2', text: 'second'),
          FootnoteModel(id: 'fn-3', text: 'third'),
        ],
      );
      final round = SectionModel.fromJson(s.toJson());
      expect(
        round.footnotes.map((f) => f.id).toList(),
        equals(['fn-1', 'fn-2', 'fn-3']),
      );
      expect(round.footnotes[1].text, equals('second'));
    });

    test('legacy section JSON without a footnotes key parses cleanly', () {
      final json = <String, dynamic>{
        'id': 's-legacy',
        'title': 'Pre-footnotes section',
        'content': '',
        'canvasData': '',
        'sectionColor': Colors.deepPurple.toARGB32(),
        'isSynced': true,
        'createdAt': '2025-01-01T00:00:00Z',
        'updatedAt': '2025-01-01T00:00:00Z',
        'parentId': null,
        'order': 0,
        'kind': 'chapter',
        'synopsis': '',
        'notes': '',
        'labelColor': null,
        'keywords': <String>[],
        'includeInPublish': true,
        // no 'footnotes' key — older Hive payloads
      };
      final s = SectionModel.fromJson(json);
      expect(s.footnotes, isEmpty);
    });

    test('malformed footnote entries are dropped, not crashy', () {
      final json = <String, dynamic>{
        'id': 's-3',
        'title': 't',
        'content': '',
        'canvasData': '',
        'sectionColor': Colors.cyan.toARGB32(),
        'createdAt': '2025-01-01T00:00:00Z',
        'updatedAt': '2025-01-01T00:00:00Z',
        'order': 0,
        'kind': 'chapter',
        'synopsis': '',
        'notes': '',
        'keywords': <String>[],
        'includeInPublish': true,
        'footnotes': [
          {'id': 'fn-good', 'text': 'kept'},
          'this should be a map',
          42,
          null,
          {'no_id_here': 'oops'},
        ],
      };
      final s = SectionModel.fromJson(json);
      // Only the well-formed entry survives.
      expect(s.footnotes.length, equals(1));
      expect(s.footnotes.first.id, equals('fn-good'));
    });
  });
}
