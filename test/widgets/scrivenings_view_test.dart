import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/scrivenings_session.dart';
import 'package:inkspacex/services/scrivenings_scroll_store.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/views/scrivenings_view.dart';

WritingModel _book(String id, List<SectionModel> sections) => WritingModel(
      id: id,
      title: 'Book',
      sections: sections,
      author: 'a',
      description: 'd',
      coverImagePath: '',
      writingType: WritingType.values.first,
      subtype: '',
    );

SectionModel _chapter({
  required String id,
  String title = 'Untitled',
  int order = 0,
  String content = '',
  bool includeInPublish = true,
  SectionKind kind = SectionKind.chapter,
}) =>
    SectionModel(
      id: id,
      title: title,
      content: content,
      sectionColor: const Color(0xFF1982C4),
      order: order,
      kind: kind,
      includeInPublish: includeInPublish,
    );

String _docJson(String text) =>
    jsonEncode([{'insert': text.isEmpty ? '\n' : '$text\n'}]);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ScrivenningsScrollStore.debugUseMemoryStore({});
  });

  tearDown(() {
    ScrivenningsScrollStore.debugUseMemoryStore(null);
  });

  testWidgets('renders one editable QuillEditor per publishable section',
      (tester) async {
    final s1 = _chapter(id: 's1', title: 'Chapter One', order: 0);
    final s2 = _chapter(id: 's2', title: 'Chapter Two', order: 1);
    final book = _book('book-1', [s1, s2]);
    final session = ScrivenningsSession(
      book: book,
      onSectionPersist: (_, _) async {},
      onFocusChanged: (_) {},
      onTypingStateChanged: (_) {},
      smartSubstitutionsEnabled: () => false,
      typingHapticsEnabled: () => false,
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScrivenningsView(
          onJumpToSection: (_) {},
          bookOverride: book,
          sessionOverride: session,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Chapter One'), findsOneWidget);
    expect(find.text('Chapter Two'), findsOneWidget);
    // Two QuillEditor instances rendered.
    expect(find.byType(QuillEditor), findsNWidgets(2));
    // Session has registered both controllers.
    expect(session.registeredSectionIds, containsAll(['s1', 's2']));
    // The 'Open in Draft' pencil button per section is present.
    expect(find.byTooltip('Open this section in Draft'), findsNWidgets(2));
  });

  testWidgets('empty state when no publishable sections', (tester) async {
    final folder = _chapter(id: 'f', kind: SectionKind.folder);
    final book = _book('book-1', [folder]);
    final session = ScrivenningsSession(
      book: book,
      onSectionPersist: (_, _) async {},
      onFocusChanged: (_) {},
      onTypingStateChanged: (_) {},
      smartSubstitutionsEnabled: () => false,
      typingHapticsEnabled: () => false,
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScrivenningsView(
          onJumpToSection: (_) {},
          bookOverride: book,
          sessionOverride: session,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Add a chapter or scene to start writing.'),
        findsOneWidget);
    expect(find.byType(QuillEditor), findsNothing);
  });

  testWidgets('pencil button calls onJumpToSection with the right section',
      (tester) async {
    final s1 = _chapter(id: 's1', title: 'One', order: 0);
    final s2 = _chapter(id: 's2', title: 'Two', order: 1);
    final book = _book('book-1', [s1, s2]);
    final session = ScrivenningsSession(
      book: book,
      onSectionPersist: (_, _) async {},
      onFocusChanged: (_) {},
      onTypingStateChanged: (_) {},
      smartSubstitutionsEnabled: () => false,
      typingHapticsEnabled: () => false,
    );
    addTearDown(session.dispose);

    SectionModel? jumped;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScrivenningsView(
          onJumpToSection: (s) => jumped = s,
          bookOverride: book,
          sessionOverride: session,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Tap the second pencil; sections render in `order`, so index 1 = s2.
    await tester.tap(find.byTooltip('Open this section in Draft').last);
    await tester.pump();
    expect(jumped?.id, 's2');
  });

  testWidgets('typing into a section dirties only that section', (tester) async {
    final s1 = _chapter(id: 's1', title: 'One', order: 0, content: _docJson(''));
    final s2 = _chapter(id: 's2', title: 'Two', order: 1, content: _docJson(''));
    final book = _book('book-1', [s1, s2]);
    final persists = <(String, String)>[];
    final session = ScrivenningsSession(
      book: book,
      onSectionPersist: (section, content) async {
        persists.add((section.id, content));
      },
      onFocusChanged: (_) {},
      onTypingStateChanged: (_) {},
      smartSubstitutionsEnabled: () => false,
      typingHapticsEnabled: () => false,
      autoSaveDebounce: const Duration(milliseconds: 30),
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScrivenningsView(
          onJumpToSection: (_) {},
          bookOverride: book,
          sessionOverride: session,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Reach into the session for the s1 controller and apply a synthetic
    // edit — driving QuillEditor through a real keypress in widget tests
    // is fragile; the controller-level edit exercises the same listener
    // chain the editor would.
    final c1 = session.register(s1);
    c1.replaceText(0, 0, 'hello', null);
    await tester.pump(const Duration(milliseconds: 50));

    expect(persists, hasLength(1));
    expect(persists.first.$1, 's1');
    expect(persists.first.$2, contains('hello'));

    // s2 hasn't been touched — no persist call for it.
    expect(persists.where((e) => e.$1 == 's2'), isEmpty);
  });

  testWidgets('research / trash / hidden sections are filtered out',
      (tester) async {
    final book = _book('b', [
      _chapter(id: 'c1', title: 'Pub', order: 0),
      _chapter(id: 'r1', kind: SectionKind.research, title: 'Research'),
      _chapter(id: 't1', kind: SectionKind.trash, title: 'Trash'),
      _chapter(id: 'h1', includeInPublish: false, title: 'Hidden'),
      _chapter(id: 'a1', kind: SectionKind.act, title: 'Act'),
    ]);
    final session = ScrivenningsSession(
      book: book,
      onSectionPersist: (_, _) async {},
      onFocusChanged: (_) {},
      onTypingStateChanged: (_) {},
      smartSubstitutionsEnabled: () => false,
      typingHapticsEnabled: () => false,
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScrivenningsView(
          onJumpToSection: (_) {},
          bookOverride: book,
          sessionOverride: session,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Pub'), findsOneWidget);
    expect(find.text('Research'), findsNothing);
    expect(find.text('Trash'), findsNothing);
    expect(find.text('Hidden'), findsNothing);
    expect(find.text('Act'), findsNothing);
  });

  testWidgets('per-project scroll position is persisted on scroll', (tester) async {
    final mem = <String, double>{};
    ScrivenningsScrollStore.debugUseMemoryStore(mem);

    // Many tall sections so the list is actually scrollable.
    final sections = List.generate(
      40,
      (i) => _chapter(
        id: 's$i',
        title: 'Section $i',
        order: i,
        content: _docJson('line ' * 10),
      ),
    );
    final book = _book('book-A', sections);
    final session = ScrivenningsSession(
      book: book,
      onSectionPersist: (_, _) async {},
      onFocusChanged: (_) {},
      onTypingStateChanged: (_) {},
      smartSubstitutionsEnabled: () => false,
      typingHapticsEnabled: () => false,
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScrivenningsView(
          onJumpToSection: (_) {},
          bookOverride: book,
          sessionOverride: session,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Drag to scroll, then wait past the 400ms debounce.
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // Some non-zero offset got persisted under our book's key.
    expect(mem.entries, isNotEmpty);
    expect(mem.entries.first.key, contains('book-A'));
    expect(mem.entries.first.value, greaterThan(0));
  });

  testWidgets('reorder preserves per-section controllers and cursor state',
      (tester) async {
    final s1 =
        _chapter(id: 's1', title: 'A', order: 0, content: _docJson('alpha'));
    final s2 =
        _chapter(id: 's2', title: 'B', order: 1, content: _docJson('beta'));
    final book = _book('b', [s1, s2]);
    final session = ScrivenningsSession(
      book: book,
      onSectionPersist: (_, _) async {},
      onFocusChanged: (_) {},
      onTypingStateChanged: (_) {},
      smartSubstitutionsEnabled: () => false,
      typingHapticsEnabled: () => false,
    );
    addTearDown(session.dispose);

    Widget tree() => MaterialApp(
          home: Scaffold(
            body: ScrivenningsView(
              onJumpToSection: (_) {},
              bookOverride: book,
              sessionOverride: session,
            ),
          ),
        );

    await tester.pumpWidget(tree());
    await tester.pumpAndSettle();

    final c1 = session.register(s1);
    // Move cursor to position 3 in section 1.
    c1.updateSelection(
        const TextSelection.collapsed(offset: 3), ChangeSource.local);
    final identityBeforeReorder = identityHashCode(c1);

    // Reorder the underlying book — section 2 moves to the top.
    s1.order = 1;
    s2.order = 0;
    await tester.pumpWidget(tree());
    await tester.pumpAndSettle();

    final c1AfterReorder = session.register(s1);
    expect(identityHashCode(c1AfterReorder), identityBeforeReorder,
        reason: 'controller identity must survive reorder (keyed by section id)');
    expect(c1AfterReorder.selection.baseOffset, 3,
        reason: 'cursor offset within the section is preserved');
  });
}
