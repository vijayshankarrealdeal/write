// Cross-feature integration smoke tests.
//
// Each P1/P2 surface (footnotes, author bookmarks, scrivenings live,
// linguistic focus, smart substitutions, page view) was shipped behind
// its own unit/widget tests. These tests catch the second-order
// breakage: feature A's silent compose nudges feature B's offsets,
// feature C's overlay survives feature D's autocorrect, etc.
//
// Tests intentionally stay at the model + service layer (no editor
// widget mounting) so they can run in CI without a render harness and
// stay fast. The contract being verified is the *integration* of the
// underlying primitives — not the UI plumbing, which is covered by the
// per-feature widget tests.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:inkspacex/models/author_bookmark.dart';
import 'package:inkspacex/models/footnote_model.dart';
import 'package:inkspacex/models/page_layout_settings.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/linguistic_focus_decoration.dart';
import 'package:inkspacex/services/linguistic_focus_service.dart';
import 'package:inkspacex/services/scrivenings_session.dart';
import 'package:inkspacex/services/smart_substitutions.dart';
import 'package:inkspacex/ui/editor/footnote_embed_builder.dart';

WritingModel _book(
  List<SectionModel> sections, {
  PageLayoutSettings? pageLayout,
}) =>
    WritingModel(
      id: 'book-cf',
      title: 'cf',
      sections: sections,
      author: 'a',
      description: 'd',
      coverImagePath: '',
      writingType: WritingType.values.first,
      subtype: '',
      pageLayout: pageLayout,
    );

SectionModel _section({
  required String id,
  String title = 't',
  String content = '',
  List<FootnoteModel>? footnotes,
}) =>
    SectionModel(
      id: id,
      title: title,
      content: content,
      sectionColor: const Color(0xFF1982C4),
      footnotes: footnotes,
    );

String _emptyDoc() => jsonEncode([
      {'insert': '\n'},
    ]);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Footnotes + author bookmarks coexist on the same paragraph', () {
    // The two features both touch a section but live in different
    // dimensions: footnotes sit inside the Quill delta as inline
    // BlockEmbeds + a parallel `footnotes` list on the section;
    // author bookmarks live outside the delta as separate rows keyed
    // by `(section_id, offset)`. The risk is that a JSON round-trip
    // of one corrupts the other, or that both pointing at the same
    // paragraph silently drops one.

    test(
      'section JSON round-trip preserves footnotes when an author '
      'bookmark targets the same offset',
      () {
        // Build a section whose Quill delta embeds a footnote inline
        // at character offset 10, and a separate AuthorBookmark whose
        // `offset` lands inside the same paragraph.
        final delta = jsonEncode([
          {'insert': 'Once upon '},
          {
            'insert': {FootnoteBlockEmbed.footnoteType: 'fn-1'}
          },
          {'insert': ' a time.\n'},
        ]);
        final section = _section(
          id: 's1',
          content: delta,
          footnotes: [FootnoteModel(id: 'fn-1', text: 'Citation [1].')],
        );
        final bookmark = AuthorBookmark(
          id: 'bm-1',
          writingId: 'book-cf',
          sectionId: 's1',
          offset: 10, // sits next to the footnote embed
          label: 'pacing check',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        );

        // The two features are independent at the persistence layer.
        // Round-trip the section through JSON and verify the footnote
        // survives without seeing the bookmark — and the bookmark's
        // create payload is well-formed without the section having to
        // know about it.
        final restored = SectionModel.fromJson(section.toJson());
        expect(restored.footnotes, hasLength(1));
        expect(restored.footnotes.first.id, 'fn-1');
        expect(restored.footnotes.first.text, 'Citation [1].');
        expect(restored.content, contains(FootnoteBlockEmbed.footnoteType));

        final create = bookmark.toCreateJson(clientOpId: 'op-9');
        expect(create['section_id'], 's1');
        expect(create['offset'], 10);
        expect(create['label'], 'pacing check');
        expect(create['client_op_id'], 'op-9');
      },
    );

    test(
      'a delete that wipes a footnote-anchored slice still moves '
      'an author bookmark that pointed past it',
      () {
        // Verifies the bookmark offset-shift math doesn't depend on
        // the embed's *byte* width: the doc-op delta speaks plain
        // codepoints and a footnote embed counts as a single
        // character, so deleting the embed should bump the bookmark
        // back by 1 (not by the JSON length of the embed).
        final initial = 12;
        final ops = [
          const DocOp.retain(10), // skip past "Once upon "
          const DocOp.delete(1), // wipe the footnote embed character
        ];
        final next = adjustOffsetForDelta(initial, ops);
        // Initial offset 12 → after deleting one embed character at 10
        // the marker shifts to 11 (pulled back by the codepoint count
        // of the deletion, not by the embed's serialized size).
        expect(next, 11);
      },
    );
  });

  group(
    'Smart substitutions compute correctly while linguistic focus '
    'marks are layered on the document',
    () {
      // Risk: linguistic-focus paints inline `linguistic-highlight` /
      // `linguistic-dim` attributes via silent compose. Smart
      // substitutions read plain text + decide a single-character
      // fix-up — the inline attributes must not corrupt that.

      test(
        'compute returns the correct quote even when surrounding text '
        'carries linguistic-focus attributes (compute is plain-text only)',
        () {
          // After: 'She said "hello'  (insertion of the leading quote)
          final result = SmartSubstitutions.compute(
            textAfter: 'She said "hello',
            insertOffset: 9, // the inserted "
            inserted: '"',
          );
          expect(result, isNotNull);
          // After a space the rule fires "opening" curly quote.
          expect(result!.replacement, '“');
          expect(result.start, 9);
          expect(result.length, 1);
        },
      );

      test(
        'applyLinguisticFocus uses ChangeSource.silent so smart '
        'substitutions and autosave are not retriggered by the overlay',
        () {
          final controller = QuillController.basic();
          controller.document = Document.fromJson([
            {'insert': 'She said hello loudly.\n'}
          ]);
          var localChanges = 0;
          var silentChanges = 0;
          final sub = controller.document.changes.listen((event) {
            if (event.source == ChangeSource.silent) {
              silentChanges++;
            } else if (event.source == ChangeSource.local) {
              localChanges++;
            }
          });

          applyLinguisticFocus(
            controller,
            activeClass: LinguisticClass.adverbs,
            highlightSpans: const [
              // "loudly" — adverb at offset 15, length 6
              LinguisticSpan(start: 15, length: 6),
            ],
          );

          // Drain any pending stream events.
          return Future<void>.delayed(Duration.zero).then((_) {
            sub.cancel();
            controller.dispose();
            // The compose must be silent so editor-side listeners that
            // gate on local changes (smart substitutions, autosave,
            // typing haptics, version snapshotting) stay quiet.
            expect(silentChanges, greaterThan(0));
            expect(localChanges, 0);
          });
        },
      );

      test(
        'stripLinguisticAttrs scrubs overlay marks before persistence '
        'so a footnote embed serialized alongside the highlight comes '
        'back without the transient mark',
        () {
          final delta = Delta()
            ..insert(
              'A loud cat',
              {kLinguisticHighlightKey: 'adjectives'},
            )
            ..insert({FootnoteBlockEmbed.footnoteType: 'fn-1'})
            ..insert('.\n');
          final clean = stripLinguisticAttrs(delta);
          // Only the highlight attribute is gone — the embed and text
          // survive untouched.
          final ops = clean.toList();
          expect(ops.first.attributes, isNull);
          // The footnote embed op is preserved verbatim.
          final embedOp = ops.firstWhere(
            (op) =>
                op.data is Map &&
                (op.data as Map).containsKey(
                  FootnoteBlockEmbed.footnoteType,
                ),
          );
          expect(
            (embedOp.data as Map)[FootnoteBlockEmbed.footnoteType],
            'fn-1',
          );
        },
      );
    },
  );

  group(
    'Comment anchors survive a linguistic-focus repaint',
    () {
      // Editor-side comments live in AnnotationProvider.shiftAnchors
      // gets called on every text-shaped edit. The linguistic-focus
      // overlay only mutates *attributes* (silent compose, no
      // text-change). Verify the no-text-change contract — that's
      // what guarantees comments stay anchored across an overlay
      // repaint.

      test(
        'applyLinguisticFocus does not modify the document plain text',
        () {
          final controller = QuillController.basic();
          controller.document = Document.fromJson([
            {'insert': 'The fox jumps over the lazy dog.\n'}
          ]);
          final before = controller.document.toPlainText();

          applyLinguisticFocus(
            controller,
            activeClass: LinguisticClass.verbs,
            highlightSpans: const [
              LinguisticSpan(start: 8, length: 5), // "jumps"
            ],
          );

          final after = controller.document.toPlainText();
          // The plain text — what comment anchors are computed against —
          // is byte-identical before and after the overlay paint.
          expect(after, before);
          controller.dispose();
        },
      );

      test(
        'a complement-style dim layer preserves length even when '
        'highlight ranges abut the document end',
        () {
          // Edge case: a highlight at the very end of the doc must
          // not drag the trailing `\n` into the dim layer (that would
          // shift selection arithmetic and corrupt comment anchors
          // that target the final paragraph).
          final controller = QuillController.basic();
          controller.document = Document.fromJson([
            {'insert': 'Adjectives at the end: small.\n'}
          ]);
          final lengthBefore = controller.document.length;

          applyLinguisticFocus(
            controller,
            activeClass: LinguisticClass.adjectives,
            highlightSpans: const [
              LinguisticSpan(start: 23, length: 5), // "small"
            ],
          );

          expect(controller.document.length, lengthBefore);
          controller.dispose();
        },
      );
    },
  );

  group(
    'Scrivenings live editing works on writings with pageLayout settings',
    () {
      // Page view stores its render config on `WritingModel.pageLayout`.
      // Scrivenings is a separate render mode that owns one
      // QuillController per section. The two should be orthogonal —
      // confirm the session ignores `pageLayout` entirely and that a
      // round-trip through JSON keeps both intact.

      test(
        'session.register builds controllers and edits flow to the '
        'persist callback even when the book has a pageLayout',
        () async {
          final s1 = _section(id: 's1', content: _emptyDoc());
          final book = _book(
            [s1],
            pageLayout: PageLayoutSettings.standard,
          );
          expect(book.pageLayout, isNotNull);

          final persisted = <String>[];
          final session = ScrivenningsSession(
            book: book,
            onSectionPersist: (section, content) async {
              persisted.add(section.id);
            },
            onFocusChanged: (_) {},
            onTypingStateChanged: (_) {},
            smartSubstitutionsEnabled: () => false,
            typingHapticsEnabled: () => false,
            autoSaveDebounce: const Duration(milliseconds: 1),
          );

          final c1 = session.register(s1);
          c1.document.insert(0, 'Hello world');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await session.flushAll();

          expect(persisted, ['s1']);
          await session.dispose();
        },
      );

      test(
        'WritingModel JSON round-trip keeps pageLayout and footnoted '
        'sections intact when scrivenings would mount them all',
        () {
          final s1 = _section(
            id: 's1',
            content: _emptyDoc(),
            footnotes: [FootnoteModel(id: 'fn-a', text: 'note A')],
          );
          final s2 = _section(id: 's2', content: _emptyDoc());
          final book = _book(
            [s1, s2],
            pageLayout: PageLayoutSettings.standard,
          );

          final restored = WritingModel.fromJson(book.toJson());
          expect(restored.pageLayout, isNotNull);
          expect(restored.pageLayout!.size, PageSize.letter);
          expect(restored.sections, hasLength(2));
          expect(restored.sections.first.footnotes, hasLength(1));
          expect(restored.sections.first.footnotes.first.id, 'fn-a');
        },
      );
    },
  );
}
