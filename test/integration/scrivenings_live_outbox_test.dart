import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/scrivenings_session.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/pending_op.dart';

/// Integration test for the live Scrivenings persistence contract:
/// edits in the per-section session must land in the outbox as
/// `upsertSection` ops with the correct writingId / sectionId, exactly
/// like single-section autosave does. The full [EditorProvider] is not
/// constructed here — its `_persistScrivenningsSection` callback is the
/// only piece worth wiring end-to-end against the real Outbox, and we
/// inline the same shape into the test so a refactor that breaks the
/// contract trips this test.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrivenings_int_');
    Hive.init(tmp.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('typing a section produces an upsertSection op with the right ids',
      () async {
    final outbox = Outbox(boxName: 'scrivenings_int_box');
    await outbox.init();

    final book = WritingModel(
      id: 'book-A',
      title: 'B',
      sections: [
        SectionModel(
          id: 'sec-1',
          title: 'One',
          content: '',
          sectionColor: const Color(0xFF1982C4),
        ),
        SectionModel(
          id: 'sec-2',
          title: 'Two',
          content: '',
          sectionColor: const Color(0xFF1982C4),
        ),
      ],
      author: 'a',
      description: 'd',
      coverImagePath: '',
      writingType: WritingType.values.first,
      subtype: '',
    );

    final session = ScrivenningsSession(
      book: book,
      onSectionPersist: (section, contentJson) async {
        // This mirrors EditorProvider._persistScrivenningsSection — the
        // shape under test.
        section.content = contentJson;
        section.isSynced = false;
        await outbox.enqueue(PendingOp(
          kind: PendingOpKind.upsertSection,
          payload: {
            'writingId': book.id,
            'sectionId': section.id,
            'isNew': false,
            'fields': {'content': contentJson},
          },
        ));
      },
      onFocusChanged: (_) {},
      onTypingStateChanged: (_) {},
      smartSubstitutionsEnabled: () => false,
      typingHapticsEnabled: () => false,
      autoSaveDebounce: const Duration(milliseconds: 30),
    );

    final c1 = session.register(book.sections[0]);
    final c2 = session.register(book.sections[1]);

    c1.replaceText(0, 0, 'first', null);
    c2.replaceText(0, 0, 'second', null);
    // Past the debounce.
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final ops = outbox.snapshot();
    expect(ops, hasLength(2));
    final byId = {for (final op in ops) op.payload['sectionId']: op};
    expect(byId.keys, containsAll(['sec-1', 'sec-2']));
    for (final op in ops) {
      expect(op.kind, PendingOpKind.upsertSection);
      expect(op.payload['writingId'], 'book-A');
      expect(op.payload['isNew'], false);
      final fields = op.payload['fields'] as Map;
      expect(fields['content'], isA<String>());
    }
    // Each section's local model carries the new serialized content.
    expect(book.sections[0].content, contains('first'));
    expect(book.sections[1].content, contains('second'));
    expect(book.sections[0].isSynced, isFalse);
    expect(book.sections[1].isSynced, isFalse);

    await session.dispose();
    await outbox.dispose();
  });

  test('flushAll fires before any debounce expires', () async {
    final outbox = Outbox(boxName: 'scrivenings_flush_box');
    await outbox.init();

    final book = WritingModel(
      id: 'b',
      title: 't',
      sections: [
        SectionModel(
          id: 's1',
          title: 't',
          content: '',
          sectionColor: const Color(0xFF1982C4),
        ),
      ],
      author: 'a',
      description: 'd',
      coverImagePath: '',
      writingType: WritingType.values.first,
      subtype: '',
    );

    final session = ScrivenningsSession(
      book: book,
      onSectionPersist: (section, content) async {
        await outbox.enqueue(PendingOp(
          kind: PendingOpKind.upsertSection,
          payload: {
            'writingId': book.id,
            'sectionId': section.id,
            'isNew': false,
            'fields': {'content': content},
          },
        ));
      },
      onFocusChanged: (_) {},
      onTypingStateChanged: (_) {},
      smartSubstitutionsEnabled: () => false,
      typingHapticsEnabled: () => false,
      autoSaveDebounce: const Duration(seconds: 60),
    );

    final c = session.register(book.sections.first);
    c.replaceText(0, 0, 'urgent', null);
    // Allow doc-changes listener to run.
    await Future<void>.delayed(Duration.zero);
    expect(outbox.length, 0); // debounce hasn't fired

    await session.flushAll();
    expect(outbox.length, 1);

    await session.dispose();
    await outbox.dispose();
  });

  test('refreshSectionContent applies a remote update to a live controller',
      () async {
    final book = WritingModel(
      id: 'b',
      title: 't',
      sections: [
        SectionModel(
          id: 's1',
          title: 't',
          content: '',
          sectionColor: const Color(0xFF1982C4),
        ),
      ],
      author: 'a',
      description: 'd',
      coverImagePath: '',
      writingType: WritingType.values.first,
      subtype: '',
    );
    final session = ScrivenningsSession(
      book: book,
      onSectionPersist: (_, _) async {},
      onFocusChanged: (_) {},
      onTypingStateChanged: (_) {},
      smartSubstitutionsEnabled: () => false,
      typingHapticsEnabled: () => false,
    );
    final c = session.register(book.sections.first);
    expect(c.document.toPlainText().trim(), isEmpty);

    // Simulate a remote section.updated event flowing through the
    // provider into refreshSectionContent.
    book.sections.first.content = '[{"insert":"Remote text\\n"}]';
    session.refreshSectionContent(book.sections.first);
    expect(c.document.toPlainText(), contains('Remote text'));

    await session.dispose();
  });
}
