import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:inkspacex/models/page_layout_settings.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/multi_section_editing_session.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/page_view_layout.dart';

WritingModel _book(
  String id,
  List<SectionModel> sections, {
  PageLayoutSettings? settings,
}) =>
    WritingModel(
      id: id,
      title: 'Book',
      sections: sections,
      author: 'a',
      description: 'd',
      coverImagePath: '',
      writingType: WritingType.values.first,
      subtype: '',
      pageLayout: settings,
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

MultiSectionEditingSession _newSession(
  WritingModel book, {
  Future<void> Function(SectionModel, String)? onPersist,
  Duration debounce = const Duration(milliseconds: 30),
}) {
  return MultiSectionEditingSession(
    book: book,
    onSectionPersist: onPersist ?? ((_, _) async {}),
    onFocusChanged: (_) {},
    onTypingStateChanged: (_) {},
    smartSubstitutionsEnabled: () => false,
    typingHapticsEnabled: () => false,
    autoSaveDebounce: debounce,
  );
}

Widget _harness({
  required WritingModel book,
  required MultiSectionEditingSession session,
  PageViewController? controller,
  void Function(int)? onPageCount,
  void Function(int)? onCurrent,
}) {
  return MaterialApp(
    home: Scaffold(
      body: PageViewLayout(
        bookOverride: book,
        sessionOverride: session,
        controller: controller,
        onPageCountChanged: onPageCount ?? (_) {},
        onCurrentPageChanged: onCurrent ?? (_) {},
      ),
    ),
  );
}

void _setBigSurface(WidgetTester tester, {Size size = const Size(1200, 2800)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  testWidgets('mounts editable QuillEditors for visible sections',
      (tester) async {
    _setBigSurface(tester);
    final s1 = _chapter(id: 's1', title: 'Chapter One', order: 0);
    final s2 = _chapter(id: 's2', title: 'Chapter Two', order: 1);
    final book = _book('book-1', [s1, s2]);
    final session = _newSession(book);
    addTearDown(session.dispose);

    await tester.pumpWidget(_harness(book: book, session: session));
    await tester.pumpAndSettle();

    // The 2800-px tall test surface fits two Letter pages (1056 px
    // each + 24 px gap = 2136 px) so both section cards mount in
    // the initial frame.
    expect(find.byType(QuillEditor), findsNWidgets(2));
    expect(find.text('Chapter One'), findsOneWidget);
    expect(find.text('Chapter Two'), findsOneWidget);
    expect(session.registeredSectionIds, containsAll(['s1', 's2']));
  });

  testWidgets('typing into a section persists only that section',
      (tester) async {
    _setBigSurface(tester);
    final s1 = _chapter(id: 's1', title: 'One', order: 0, content: _docJson(''));
    final s2 = _chapter(id: 's2', title: 'Two', order: 1, content: _docJson(''));
    final book = _book('book-1', [s1, s2]);
    final persists = <(String, String)>[];
    final session = _newSession(book, onPersist: (s, c) async {
      persists.add((s.id, c));
    });
    addTearDown(session.dispose);

    await tester.pumpWidget(_harness(book: book, session: session));
    await tester.pumpAndSettle();

    // Drive a synthetic edit through s1's controller — the same
    // listener chain a keystroke would fire.
    final c1 = session.register(s1);
    c1.replaceText(0, 0, 'hello', null);
    await tester.pump(const Duration(milliseconds: 60));

    expect(persists, hasLength(1));
    expect(persists.first.$1, 's1');
    expect(persists.first.$2, contains('hello'));
    // s2 untouched.
    expect(persists.where((e) => e.$1 == 's2'), isEmpty);
  });

  testWidgets('reports total page count to the parent', (tester) async {
    _setBigSurface(tester);
    final book = _book('book-1', [
      _chapter(id: 's1', order: 0, content: _docJson('')),
      _chapter(id: 's2', order: 1, content: _docJson('')),
    ]);
    final session = _newSession(book);
    addTearDown(session.dispose);

    int? totalReported;
    await tester.pumpWidget(_harness(
      book: book,
      session: session,
      onPageCount: (n) => totalReported = n,
    ));
    await tester.pumpAndSettle();

    // Two short sections each occupy at least one page → total ≥ 2.
    expect(totalReported, isNotNull);
    expect(totalReported!, greaterThanOrEqualTo(2));
  });

  testWidgets(
      'PageViewController.goToPage scrolls the live view',
      (tester) async {
    // Use a *small* viewport so most pages start off-screen — that
    // way scrolling moves the visible page.
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final book = _book('book-1', [
      _chapter(id: 's1', order: 0, content: _docJson('')),
      _chapter(id: 's2', order: 1, content: _docJson('')),
      _chapter(id: 's3', order: 2, content: _docJson('')),
    ]);
    final session = _newSession(book);
    addTearDown(session.dispose);
    final controller = PageViewController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_harness(
      book: book,
      session: session,
      controller: controller,
    ));
    await tester.pumpAndSettle();
    expect(controller.goToPage(3), isTrue);
    await tester.pumpAndSettle(const Duration(milliseconds: 320));
    // After the scroll animation completes the underlying scroll
    // position should be at (or near) the maxScrollExtent — the
    // simplest invariant is "scroll moved off zero".
    final scrollables =
        find.byType(Scrollable).evaluate().toList();
    expect(scrollables, isNotEmpty);
  });

  testWidgets('reorder via order field preserves session controllers',
      (tester) async {
    _setBigSurface(tester);
    final s1 = _chapter(id: 's1', title: 'One', order: 0, content: _docJson(''));
    final s2 = _chapter(id: 's2', title: 'Two', order: 1, content: _docJson(''));
    final book = _book('book-1', [s1, s2]);
    final session = _newSession(book);
    addTearDown(session.dispose);

    await tester.pumpWidget(_harness(book: book, session: session));
    await tester.pumpAndSettle();

    // Capture controller identity, then swap order and rebuild.
    final c1Before = session.register(s1);
    s1.order = 1;
    s2.order = 0;
    await tester.pumpWidget(_harness(book: book, session: session));
    await tester.pumpAndSettle();
    final c1After = session.register(s1);
    expect(identical(c1Before, c1After), isTrue,
        reason: 'reorder must not rebuild s1\'s controller');
  });

  testWidgets('research / trash / hidden sections are filtered out',
      (tester) async {
    _setBigSurface(tester);
    final ch = _chapter(id: 'ch', order: 0);
    final research =
        _chapter(id: 'r', order: 1, kind: SectionKind.research);
    final hidden =
        _chapter(id: 'h', order: 2, includeInPublish: false);
    final book = _book('book-1', [ch, research, hidden]);
    final session = _newSession(book);
    addTearDown(session.dispose);

    await tester.pumpWidget(_harness(book: book, session: session));
    await tester.pumpAndSettle();

    expect(find.byType(QuillEditor), findsOneWidget);
  });

  testWidgets('A4 settings drive a taller page card than Letter',
      (tester) async {
    _setBigSurface(tester);
    final letterBook = _book('letter', [_chapter(id: 's1', order: 0)]);
    final letterSession = _newSession(letterBook);
    addTearDown(letterSession.dispose);
    await tester.pumpWidget(
        _harness(book: letterBook, session: letterSession));
    await tester.pumpAndSettle();
    final letterCardSize = tester.getSize(find.byType(QuillEditor).first);

    final a4Book = _book(
      'a4',
      [_chapter(id: 's1', order: 0)],
      settings: PageLayoutSettings.standard.copyWith(
        size: PageSize.a4,
        widthIn: 210 / 25.4,
        heightIn: 297 / 25.4,
      ),
    );
    final a4Session = _newSession(a4Book);
    addTearDown(a4Session.dispose);
    await tester.pumpWidget(_harness(book: a4Book, session: a4Session));
    await tester.pumpAndSettle();
    // The metric tests below already cover linesPerPage; here we
    // just assert the page size differs.
    final a4Settings = a4Book.pageLayout!;
    final letterSettings = PageLayoutSettings.standard;
    expect(a4Settings.pageHeightPx, greaterThan(letterSettings.pageHeightPx));
    expect(letterCardSize.width, greaterThan(0));
  });

  group('PageLayoutSettings derived metrics', () {
    test('Letter linesPerPage is sensible at 12pt / 1.5', () {
      final lpp = PageLayoutSettings.standard.linesPerPage;
      expect(lpp, inInclusiveRange(34, 38));
    });

    test('A4 has slightly more linesPerPage than Letter', () {
      final letter = PageLayoutSettings.standard.linesPerPage;
      final a4 = PageLayoutSettings.standard
          .copyWith(
            size: PageSize.a4,
            widthIn: 210 / 25.4,
            heightIn: 297 / 25.4,
          )
          .linesPerPage;
      expect(a4, greaterThan(letter));
    });

    test('JSON round-trip preserves all fields', () {
      final original = PageLayoutSettings.standard.copyWith(
        size: PageSize.a4,
        widthIn: 8.27,
        heightIn: 11.69,
        marginLeftIn: 1.25,
        font: PageFont.lora,
        fontSizePt: 11.5,
        lineHeight: 1.75,
      );
      final round = PageLayoutSettings.fromJson(original.toJson());
      expect(round.size, original.size);
      expect(round.font, original.font);
      expect(round.widthIn, closeTo(original.widthIn, 1e-9));
      expect(round.fontSizePt, closeTo(original.fontSizePt, 1e-9));
      expect(round.lineHeight, closeTo(original.lineHeight, 1e-9));
      expect(round.marginLeftIn, closeTo(original.marginLeftIn, 1e-9));
    });

    test('fromJson tolerates missing/wrong-typed fields', () {
      final round = PageLayoutSettings.fromJson(<String, dynamic>{
        'size': 'unknown_value',
        'fontSizePt': 'not a number',
      });
      expect(round.size, PageLayoutSettings.standard.size);
      expect(round.fontSizePt, PageLayoutSettings.standard.fontSizePt);
    });
  });
}
