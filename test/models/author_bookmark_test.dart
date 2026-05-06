import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/models/author_bookmark.dart';

void main() {
  group('adjustOffsetForDelta', () {
    test('no ops → unchanged', () {
      expect(adjustOffsetForDelta(10, const []), 10);
    });

    test('negative input clamps to 0', () {
      expect(adjustOffsetForDelta(-5, const []), 0);
    });

    test('insert before marker shifts marker right', () {
      // Source: "ab|cd" (marker at 2). Insert "XY" at position 0.
      final ops = [const DocOp.insert(2)];
      expect(adjustOffsetForDelta(2, ops), 4);
    });

    test('insert at retain boundary (before marker) shifts marker', () {
      // Retain 1, insert 3 — insert lands at source position 1, before marker
      final ops = [const DocOp.retain(1), const DocOp.insert(3)];
      expect(adjustOffsetForDelta(5, ops), 8);
    });

    test('insert at exactly marker position shifts marker right', () {
      // Quill convention: a selection at the insertion point moves with
      // the inserted text (cursor stays "in front of" what you typed).
      final ops = [const DocOp.retain(2), const DocOp.insert(4)];
      expect(adjustOffsetForDelta(2, ops), 6);
    });

    test('insert strictly after marker leaves it alone', () {
      // Retain 5, insert 3 — insert lands at source 5, marker at 2.
      final ops = [const DocOp.retain(5), const DocOp.insert(3)];
      expect(adjustOffsetForDelta(2, ops), 2);
    });

    test('delete entirely before marker shifts left by delete length', () {
      // Retain 0, delete 3 — marker at 10 → 7.
      final ops = [const DocOp.delete(3)];
      expect(adjustOffsetForDelta(10, ops), 7);
    });

    test('delete ending exactly at marker shifts marker left to delStart',
        () {
      // Retain 4, delete 3 — delete spans source [4, 7), marker at 7.
      // delEnd == marker is treated as "before" — shift left by 3 → 4.
      final ops = [const DocOp.retain(4), const DocOp.delete(3)];
      expect(adjustOffsetForDelta(7, ops), 4);
    });

    test('delete strictly after marker leaves marker alone', () {
      final ops = [const DocOp.retain(10), const DocOp.delete(3)];
      expect(adjustOffsetForDelta(5, ops), 5);
    });

    test('delete starting exactly at marker leaves marker alone', () {
      // delStart == marker, delEnd > marker. Marker stays put.
      final ops = [const DocOp.retain(5), const DocOp.delete(3)];
      expect(adjustOffsetForDelta(5, ops), 5);
    });

    test('delete straddling marker pulls it back to delStart', () {
      // Retain 3, delete 5 — delete spans [3, 8), marker at 5.
      final ops = [const DocOp.retain(3), const DocOp.delete(5)];
      expect(adjustOffsetForDelta(5, ops), 3);
    });

    test('mixed insert + delete before marker compose correctly', () {
      // Source: "abcdefghij" (length 10), marker at 8.
      // Delete first 2 chars, then insert 5 at source position 2.
      // Expected: marker shifts -2 (delete) +5 (insert before marker) = +3 → 11.
      final ops = [
        const DocOp.delete(2),
        const DocOp.insert(5),
      ];
      expect(adjustOffsetForDelta(8, ops), 11);
    });

    test('insert at start of document shifts every marker', () {
      // Marker at 0 with insert(3) at source 0 → marker at 3 (insert at
      // exactly markerSrc shifts).
      final ops = [const DocOp.insert(3)];
      expect(adjustOffsetForDelta(0, ops), 3);
    });

    test('chain of deletes accumulate', () {
      // delete(2), retain(1), delete(2). Marker at 10.
      // First delete: delEnd=2 < marker=10 → shift -2.
      // Retain 1 → src advances to 3 (after the 2 deleted).
      // Wait — src after delete(2) is 2. retain(1) advances src to 3.
      // Then delete(2) at src=3, delEnd=5 < marker=10 → shift -2.
      // Marker target: 10 - 4 = 6.
      final ops = [
        const DocOp.delete(2),
        const DocOp.retain(1),
        const DocOp.delete(2),
      ];
      expect(adjustOffsetForDelta(10, ops), 6);
    });

    test('insert after a delete that straddles still works', () {
      // Marker at 5. Delete spans [3,7) — straddles, marker pulls to 3.
      // Then insert(2) at src=7. Since markerSrc=3 and src=7 > 3, no shift.
      final ops = [
        const DocOp.retain(3),
        const DocOp.delete(4),
        const DocOp.insert(2),
      ];
      expect(adjustOffsetForDelta(5, ops), 3);
    });

    test('delete removing the entire document collapses marker to 0', () {
      // Marker at 5, delete(20). delStart=0, delEnd=20, marker=5 →
      // straddle, markerSrc=0, shift=0. Result 0.
      final ops = [const DocOp.delete(20)];
      expect(adjustOffsetForDelta(5, ops), 0);
    });

    test(
        'multi-op realistic edit (typing in the middle): retain N + insert + retain',
        () {
      // Source: "Hello world" (11). Marker at 11 (end). User types " there" at offset 5.
      // retain(5), insert(6) — marker at 11 → shift +6 → 17.
      final ops = [const DocOp.retain(5), const DocOp.insert(6)];
      expect(adjustOffsetForDelta(11, ops), 17);
    });

    test('multi-op realistic edit (deleting a word): retain N + delete', () {
      // "Hello cruel world" (17). Delete " cruel" (6 chars) starting at 5.
      // Marker at 17 → shift -6 → 11.
      final ops = [const DocOp.retain(5), const DocOp.delete(6)];
      expect(adjustOffsetForDelta(17, ops), 11);
    });
  });

  group('AuthorBookmark serialization', () {
    test('roundtrips through JSON', () {
      final ts = DateTime.utc(2026, 5, 6, 9, 30);
      final bookmark = AuthorBookmark(
        id: 'abc',
        writingId: 'w1',
        sectionId: 's1',
        offset: 42,
        label: 'Daisy reveal',
        color: '#FF5722',
        createdAt: ts,
        updatedAt: ts,
      );
      final json = bookmark.toCreateJson(clientOpId: 'op-1');
      expect(json['writing_id'], 'w1');
      expect(json['section_id'], 's1');
      expect(json['offset'], 42);
      expect(json['label'], 'Daisy reveal');
      expect(json['color'], '#FF5722');
      expect(json['client_op_id'], 'op-1');
    });

    test('toCreateJson omits null label', () {
      final bookmark = AuthorBookmark(
        id: 'abc',
        writingId: 'w1',
        sectionId: 's1',
        offset: 0,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      final json = bookmark.toCreateJson();
      expect(json.containsKey('label'), false);
      expect(json.containsKey('client_op_id'), false);
    });

    test('fromJson tolerates missing fields with sensible defaults', () {
      final b = AuthorBookmark.fromJson(<String, dynamic>{
        'id': 'x',
        'writing_id': 'w',
        'section_id': 's',
        'offset': 7,
      });
      expect(b.color, '#FFB300');
      expect(b.label, isNull);
      expect(b.offset, 7);
    });

    test('copyWith with clearLabel drops the label', () {
      final b = AuthorBookmark(
        id: 'a',
        writingId: 'w',
        sectionId: 's',
        offset: 0,
        label: 'old',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      final cleared = b.copyWith(clearLabel: true);
      expect(cleared.label, isNull);
    });

    test('toPatchJson with clearLabel emits explicit null', () {
      final b = AuthorBookmark(
        id: 'a',
        writingId: 'w',
        sectionId: 's',
        offset: 0,
        label: 'x',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      final body = b.toPatchJson(clearLabel: true);
      expect(body['label'], isNull);
      expect(body.containsKey('label'), true);
    });
  });
}
