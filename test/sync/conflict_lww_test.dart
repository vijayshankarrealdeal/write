import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';

SectionModel _section({
  required String id,
  required String content,
  required DateTime updatedAt,
  bool isSynced = true,
}) =>
    SectionModel(
      id: id,
      title: 't',
      content: content,
      sectionColor: const Color(0xFF1982C4),
      updatedAt: updatedAt,
      isSynced: isSynced,
    );

void main() {
  group('mergeSectionsLww (last-write-wins for SectionModel)', () {
    test('local wins when newer AND unsynced', () {
      final local = [
        _section(
          id: 's1',
          content: '"local newer"',
          updatedAt: DateTime.utc(2026, 4, 26, 10),
          isSynced: false,
        ),
      ];
      final remote = [
        _section(
          id: 's1',
          content: '"remote older"',
          updatedAt: DateTime.utc(2026, 4, 26, 9),
        ),
      ];
      final merged = EditorProvider.mergeSectionsLww(local, remote);
      expect(merged.single.content, '"local newer"');
    });

    test('remote wins when newer than local', () {
      final local = [
        _section(
          id: 's1',
          content: '"local stale"',
          updatedAt: DateTime.utc(2026, 4, 26, 8),
          isSynced: false,
        ),
      ];
      final remote = [
        _section(
          id: 's1',
          content: '"remote fresh"',
          updatedAt: DateTime.utc(2026, 4, 26, 9),
        ),
      ];
      final merged = EditorProvider.mergeSectionsLww(local, remote);
      expect(merged.single.content, '"remote fresh"');
    });

    test('remote wins when local is newer but already synced', () {
      // The "isSynced" guard prevents stale local cache from clobbering
      // a server-side edit made after this client last pushed.
      final local = [
        _section(
          id: 's1',
          content: '"stale snapshot"',
          updatedAt: DateTime.utc(2026, 4, 26, 10),
          isSynced: true,
        ),
      ];
      final remote = [
        _section(
          id: 's1',
          content: '"server truth"',
          updatedAt: DateTime.utc(2026, 4, 26, 9),
        ),
      ];
      final merged = EditorProvider.mergeSectionsLww(local, remote);
      expect(merged.single.content, '"server truth"');
    });

    test('local-only sections (offline-created) are preserved', () {
      final local = [
        _section(
          id: 's-new',
          content: '"new offline section"',
          updatedAt: DateTime.utc(2026, 4, 26, 10),
          isSynced: false,
        ),
      ];
      final merged = EditorProvider.mergeSectionsLww(local, const []);
      expect(merged.single.id, 's-new');
    });

    test('onMergeDecision callback fires with the chosen winner', () {
      final calls = <String>[];
      final local = [
        _section(
          id: 's1',
          content: '"local"',
          updatedAt: DateTime.utc(2026, 4, 26, 10),
          isSynced: false,
        ),
      ];
      final remote = [
        _section(
          id: 's1',
          content: '"remote"',
          updatedAt: DateTime.utc(2026, 4, 26, 9),
        ),
      ];
      EditorProvider.mergeSectionsLww(
        local,
        remote,
        onMergeDecision: (l, r, localWins) {
          calls.add('${l.id}:${localWins ? 'local' : 'remote'}');
        },
      );
      expect(calls, ['s1:local']);
    });
  });
}
