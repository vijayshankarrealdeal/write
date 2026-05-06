import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/scrivenings_session.dart';

WritingModel _book(List<SectionModel> sections) => WritingModel(
      id: 'book-1',
      title: 'Test Book',
      sections: sections,
      author: 'a',
      description: 'd',
      coverImagePath: '',
      writingType: WritingType.values.first,
      subtype: '',
    );

SectionModel _section({
  required String id,
  String title = 't',
  String content = '',
}) =>
    SectionModel(
      id: id,
      title: title,
      content: content,
      sectionColor: const Color(0xFF1982C4),
    );

/// Build a Quill JSON payload that serializes round-trippably so equality
/// checks against `dumpData`-equivalent serialization line up. The session
/// sends every section through `Document.toDelta() -> jsonEncode`, so a
/// single `\n` insert is the canonical empty document.
String _emptyContent() => jsonEncode([
      {'insert': '\n'},
    ]);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ScrivenningsSession lifecycle', () {
    test('register builds a fresh QuillController per section', () {
      final s1 = _section(id: 's1');
      final s2 = _section(id: 's2');
      final session = ScrivenningsSession(
        book: _book([s1, s2]),
        onSectionPersist: (_, _) async {},
        onFocusChanged: (_) {},
        onTypingStateChanged: (_) {},
        smartSubstitutionsEnabled: () => false,
        typingHapticsEnabled: () => false,
      );

      final c1 = session.register(s1);
      final c2 = session.register(s2);

      expect(c1, isNot(same(c2)));
      // Idempotent — same controller on re-register.
      expect(session.register(s1), same(c1));

      session.dispose();
    });

    test('unregister flushes pending edit before dropping controller',
        () async {
      final calls = <(String, String)>[];
      final s1 = _section(id: 's1');
      final session = ScrivenningsSession(
        book: _book([s1]),
        onSectionPersist: (section, content) async {
          calls.add((section.id, content));
        },
        onFocusChanged: (_) {},
        onTypingStateChanged: (_) {},
        smartSubstitutionsEnabled: () => false,
        typingHapticsEnabled: () => false,
        autoSaveDebounce: const Duration(seconds: 30),
      );

      final c = session.register(s1);
      c.replaceText(0, 0, 'hello', null);
      await Future<void>.delayed(Duration.zero);
      // Debounce hasn't fired (30s window) — unregister forces a flush.
      await session.unregister(s1.id);
      expect(calls, hasLength(1));
      expect(calls.first.$1, 's1');
      expect(calls.first.$2, contains('hello'));
      session.dispose();
    });

    test('dispose flushes every section and is idempotent', () async {
      final calls = <String>[];
      final s1 = _section(id: 's1');
      final s2 = _section(id: 's2');
      final session = ScrivenningsSession(
        book: _book([s1, s2]),
        onSectionPersist: (section, _) async {
          calls.add(section.id);
        },
        onFocusChanged: (_) {},
        onTypingStateChanged: (_) {},
        smartSubstitutionsEnabled: () => false,
        typingHapticsEnabled: () => false,
        autoSaveDebounce: const Duration(seconds: 30),
      );

      session.register(s1).replaceText(0, 0, 'a', null);
      session.register(s2).replaceText(0, 0, 'b', null);
      await Future<void>.delayed(Duration.zero);

      await session.dispose();
      expect(calls, containsAll(['s1', 's2']));

      // Second dispose is a no-op.
      await session.dispose();

      // Using the session after dispose throws.
      expect(() => session.register(s1), throwsStateError);
    });
  });

  group('autosave', () {
    test('debounce window flushes once even on a typing burst', () async {
      final flushes = <String>[];
      final s1 = _section(id: 's1');
      final session = ScrivenningsSession(
        book: _book([s1]),
        onSectionPersist: (section, content) async {
          flushes.add(content);
        },
        onFocusChanged: (_) {},
        onTypingStateChanged: (_) {},
        smartSubstitutionsEnabled: () => false,
        typingHapticsEnabled: () => false,
        autoSaveDebounce: const Duration(milliseconds: 30),
      );

      final c = session.register(s1);
      c.replaceText(0, 0, 'a', null);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      c.replaceText(1, 0, 'b', null);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      c.replaceText(2, 0, 'c', null);
      // Now wait past the debounce.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(flushes, hasLength(1));
      expect(flushes.first, contains('abc'));

      await session.dispose();
    });

    test('typing-state callback flips on first keystroke and back on flush',
        () async {
      final transitions = <bool>[];
      final s1 = _section(id: 's1');
      final session = ScrivenningsSession(
        book: _book([s1]),
        onSectionPersist: (_, _) async {},
        onFocusChanged: (_) {},
        onTypingStateChanged: transitions.add,
        smartSubstitutionsEnabled: () => false,
        typingHapticsEnabled: () => false,
        autoSaveDebounce: const Duration(milliseconds: 20),
      );

      session.register(s1).replaceText(0, 0, 'a', null);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(transitions, [true, false]);

      await session.dispose();
    });

    test('persist callback is NOT invoked when content is unchanged',
        () async {
      final calls = <String>[];
      final s1 = _section(id: 's1', content: _emptyContent());
      final session = ScrivenningsSession(
        book: _book([s1]),
        onSectionPersist: (_, content) async {
          calls.add(content);
        },
        onFocusChanged: (_) {},
        onTypingStateChanged: (_) {},
        smartSubstitutionsEnabled: () => false,
        typingHapticsEnabled: () => false,
        autoSaveDebounce: const Duration(milliseconds: 20),
      );

      // Register but don't type — flushAll on dispose should be a no-op.
      session.register(s1);
      await session.dispose();
      expect(calls, isEmpty);
    });
  });

  group('focus tracking', () {
    testWidgets('focusing a section retargets focusedController + fires callback',
        (tester) async {
      final s1 = _section(id: 's1');
      final s2 = _section(id: 's2');
      var focusEvents = <String>[];
      final session = ScrivenningsSession(
        book: _book([s1, s2]),
        onSectionPersist: (_, _) async {},
        onFocusChanged: (s) => focusEvents.add(s.id),
        onTypingStateChanged: (_) {},
        smartSubstitutionsEnabled: () => false,
        typingHapticsEnabled: () => false,
      );
      addTearDown(session.dispose);

      session.register(s1);
      session.register(s2);
      final n1 = session.focusNode(s1);
      final n2 = session.focusNode(s2);

      // Pump a minimal tree so the FocusNodes attach to a real focus scope.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(children: [
              TextField(focusNode: n1),
              TextField(focusNode: n2),
            ]),
          ),
        ),
      );

      n1.requestFocus();
      await tester.pump();
      expect(focusEvents.last, 's1');
      expect(session.focusedSectionId, 's1');
      expect(session.focusedController, isNotNull);

      n2.requestFocus();
      await tester.pump();
      expect(focusEvents.last, 's2');
      expect(session.focusedSectionId, 's2');
    });

    test('focusedController is null until a section is focused', () {
      final session = ScrivenningsSession(
        book: _book([_section(id: 's1')]),
        onSectionPersist: (_, _) async {},
        onFocusChanged: (_) {},
        onTypingStateChanged: (_) {},
        smartSubstitutionsEnabled: () => false,
        typingHapticsEnabled: () => false,
      );
      session.register(_section(id: 's1'));
      expect(session.focusedSectionId, isNull);
      expect(session.focusedController, isNull);
      session.dispose();
    });
  });

  group('refreshSectionContent', () {
    test('rewrites the controller doc when remote content arrives', () {
      final s1 = _section(id: 's1', content: _emptyContent());
      final session = ScrivenningsSession(
        book: _book([s1]),
        onSectionPersist: (_, _) async {},
        onFocusChanged: (_) {},
        onTypingStateChanged: (_) {},
        smartSubstitutionsEnabled: () => false,
        typingHapticsEnabled: () => false,
      );
      final c = session.register(s1);
      // Mutate the underlying section as if a remote sync delivered new text.
      s1.content = jsonEncode([
        {'insert': 'remote text\n'},
      ]);
      session.refreshSectionContent(s1);
      expect(c.document.toPlainText(), contains('remote text'));
      session.dispose();
    });
  });

  group('smart substitutions', () {
    test('curly-quote rule fires per section when enabled', () async {
      final s1 = _section(id: 's1');
      final session = ScrivenningsSession(
        book: _book([s1]),
        onSectionPersist: (_, _) async {},
        onFocusChanged: (_) {},
        onTypingStateChanged: (_) {},
        smartSubstitutionsEnabled: () => true,
        typingHapticsEnabled: () => false,
        autoSaveDebounce: const Duration(milliseconds: 30),
      );
      final c = session.register(s1);
      c.replaceText(0, 0, '"', null);
      // The doc-changes stream fires asynchronously — await one tick so
      // the session's listener gets a chance to apply the substitution.
      await Future<void>.delayed(Duration.zero);
      expect(c.document.toPlainText(), startsWith('“'));
      await session.dispose();
    });

    test('toggle-off skips substitutions', () async {
      final s1 = _section(id: 's1');
      final session = ScrivenningsSession(
        book: _book([s1]),
        onSectionPersist: (_, _) async {},
        onFocusChanged: (_) {},
        onTypingStateChanged: (_) {},
        smartSubstitutionsEnabled: () => false,
        typingHapticsEnabled: () => false,
      );
      final c = session.register(s1);
      c.replaceText(0, 0, '"', null);
      await Future<void>.delayed(Duration.zero);
      expect(c.document.toPlainText(), startsWith('"'));
      await session.dispose();
    });
  });

  group('persistence shape', () {
    test('persisted JSON is the deserializable Quill delta of the section',
        () async {
      String? capturedContent;
      final s1 = _section(id: 's1');
      final session = ScrivenningsSession(
        book: _book([s1]),
        onSectionPersist: (_, content) async {
          capturedContent = content;
        },
        onFocusChanged: (_) {},
        onTypingStateChanged: (_) {},
        smartSubstitutionsEnabled: () => false,
        typingHapticsEnabled: () => false,
        autoSaveDebounce: const Duration(milliseconds: 10),
      );
      final c = session.register(s1);
      c.replaceText(0, 0, 'hello world', null);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(capturedContent, isNotNull);
      // Must round-trip into a Quill Document.
      final ops = jsonDecode(capturedContent!);
      expect(ops, isA<List<dynamic>>());
      final doc = Document.fromJson(ops as List<dynamic>);
      expect(doc.toPlainText(), contains('hello world'));
      await session.dispose();
    });
  });
}
