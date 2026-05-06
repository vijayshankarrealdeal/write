// Integration test for the live Page view: edits made through the
// shared MultiSectionEditingSession must land in the outbox as
// upsertSection ops the same way Scrivenings live does, and the
// session must survive a view swap (Scrivenings ⇄ Page) without
// losing pending writes or rebuilding controllers.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/multi_section_editing_session.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/pending_op.dart';

WritingModel _book(String id) => WritingModel(
      id: id,
      title: 'Book',
      author: 'a',
      description: 'd',
      coverImagePath: '',
      writingType: WritingType.values.first,
      subtype: '',
      sections: [
        SectionModel(
          id: 's1',
          title: 'Chapter 1',
          content: '',
          sectionColor: const Color(0xFF1982C4),
        ),
        SectionModel(
          id: 's2',
          title: 'Chapter 2',
          content: '',
          sectionColor: const Color(0xFF1982C4),
        ),
      ],
    );

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('page_view_int_');
    Hive.init(tmp.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('Page view edits land as upsertSection ops with matching ids',
      () async {
    final outbox = Outbox(boxName: 'page_view_int_box');
    await outbox.init();

    final book = _book('book-PV');
    final session = MultiSectionEditingSession(
      book: book,
      onSectionPersist: (section, contentJson) async {
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
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final ops = outbox.snapshot();
    expect(ops, hasLength(2));
    expect(book.sections[0].content, contains('first'));
    expect(book.sections[1].content, contains('second'));
    // Both ops carry the right writingId.
    for (final op in ops) {
      expect(op.kind, PendingOpKind.upsertSection);
      expect(op.payload['writingId'], 'book-PV');
    }

    await session.dispose();
    await outbox.dispose();
  });

  test('switching Scrivenings ⇄ Page keeps the session alive', () async {
    // The session should outlive a view swap — controllers, undo
    // stacks, autosave timers, and selections all survive because
    // the provider only tears down the session on the way out of
    // multi-section mode entirely.
    final outbox = Outbox(boxName: 'page_view_swap_box');
    await outbox.init();

    final book = _book('book-swap');
    final session = MultiSectionEditingSession(
      book: book,
      onSectionPersist: (section, contentJson) async {
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

    // Type in s1 while in "Scrivenings".
    final c1 = session.register(book.sections[0]);
    final c1Identity = c1;
    c1.replaceText(0, 0, 'partial', null);
    // Simulate the user swapping to Page view BEFORE autosave fires.
    // The controller identity must survive the swap.
    final c1AfterSwap = session.register(book.sections[0]);
    expect(identical(c1Identity, c1AfterSwap), isTrue,
        reason: 'view swap must reuse the same controller');
    // Allow the debounce to fire.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    // The pending edit landed in the outbox even though the user
    // changed views in between.
    final ops = outbox.snapshot();
    expect(ops, hasLength(1));
    expect(ops.first.payload['sectionId'], 's1');

    await session.dispose();
    await outbox.dispose();
  });

  test('flushAll drains every pending autosave on session teardown',
      () async {
    final outbox = Outbox(boxName: 'page_view_flush_box');
    await outbox.init();
    final book = _book('book-flush');
    final session = MultiSectionEditingSession(
      book: book,
      onSectionPersist: (section, contentJson) async {
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
      // Long debounce so the timer is still pending when we flush.
      autoSaveDebounce: const Duration(seconds: 5),
    );

    final c1 = session.register(book.sections[0]);
    c1.replaceText(0, 0, 'unsaved', null);
    // The doc-changes stream fires asynchronously — yield once so
    // the session installs an autosave timer before we flush.
    await Future<void>.delayed(Duration.zero);
    expect(outbox.snapshot(), isEmpty);
    await session.flushAll();
    expect(outbox.snapshot(), hasLength(1));

    await session.dispose();
    await outbox.dispose();
  });
}
