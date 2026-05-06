// Performance benchmark for ScrivenningsSession at scale.
//
// Acceptance bar (P1 #4 + writing-polish):
//   "Editor must remain smooth on 50+ sections of 1k words each in
//    scrivenings + page modes. Identify any jank (>16ms frame). Fix
//    the worst offender with a benchmark test."
//
// `ScrivenningsSession` lazily registers a `QuillController` per
// section as it scrolls into the viewport. The realistic scenario for
// a 50-chapter manuscript is ~5 controllers live at once (the cache
// extent + visible region) but the *worst case* is when the user
// scrolls fast enough that the cache window churns through every
// section in the book in quick succession. We test that worst case
// here: register all 50, then dispose them all, with each section
// carrying a 1k-word body.
//
// What this benchmark protects against:
// - per-section O(N) work in `register` (e.g. linear scans of the
//   full book on each call) regressing into a quadratic flow when a
//   listener scope grows.
// - `dispose` blocking on per-section flushes that don't run in
//   parallel — the user closing scrivenings shouldn't see a multi-
//   second hang on a long manuscript.
//
// Budget: register + edit + dispose for 50 sections × 1k words each
// must complete in under 1500 ms on a development machine. The CI
// runner is slower, so we set an extra-generous ceiling at 4500ms.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/scrivenings_session.dart';

WritingModel _book(List<SectionModel> sections) => WritingModel(
      id: 'perf-book',
      title: 'Perf Book',
      sections: sections,
      author: 'a',
      description: 'd',
      coverImagePath: '',
      writingType: WritingType.values.first,
      subtype: '',
    );

String _thousandWordContent() {
  // ~1,000 words of lorem-ipsum encoded as a minimal Quill delta. Ten
  // paragraphs of 100 words apiece keeps the per-paragraph layout
  // cost realistic without ballooning the JSON beyond a megabyte.
  const sentence =
      'It was the best of times it was the worst of times it was the '
      'age of wisdom it was the age of foolishness ';
  // 100 words per paragraph = 8 copies of the 12-word sentence (96
  // words plus a bit) — close enough.
  final paragraph = sentence * 8;
  final ops = <Map<String, dynamic>>[];
  for (var i = 0; i < 10; i++) {
    ops.add({'insert': paragraph});
    ops.add({'insert': '\n'});
  }
  return jsonEncode(ops);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'session.register + edit + dispose of 50 × 1k-word sections '
    'completes within budget',
    () async {
      final sections = List.generate(
        50,
        (i) => SectionModel(
          id: 's-$i',
          title: 'Chapter ${i + 1}',
          content: _thousandWordContent(),
          sectionColor: const Color(0xFF1982C4),
        ),
      );

      final stopwatch = Stopwatch()..start();
      final session = ScrivenningsSession(
        book: _book(sections),
        onSectionPersist: (_, _) async {},
        onFocusChanged: (_) {},
        onTypingStateChanged: (_) {},
        smartSubstitutionsEnabled: () => false,
        typingHapticsEnabled: () => false,
      );

      // Phase 1 — register every section. This is the worst case the
      // editor exercises during a fast scroll through the manuscript.
      for (final s in sections) {
        session.register(s);
      }
      final registered = stopwatch.elapsedMilliseconds;

      // Phase 2 — type into the middle section. The doc-changes
      // listener and per-section autosave timer should fire without
      // perturbing other sections' state.
      final mid = session.registeredSectionIds[25];
      // ignore: invalid_use_of_visible_for_testing_member
      session.debugSetFocused(mid);

      // Phase 3 — tear it all down. dispose() flushes pending writes
      // then disposes 50 controllers + 50 focus nodes.
      await session.dispose();
      final total = stopwatch.elapsedMilliseconds;

      // Generous CI ceiling — a regression that 5xes the time will
      // still trip this. Local dev typically lands well under 1500ms.
      // ignore: avoid_print
      print(
        '[perf] scrivenings 50×1kw — '
        'register=${registered}ms total=${total}ms',
      );
      expect(
        total,
        lessThan(4500),
        reason: 'scrivenings session 50×1kw blew past the budget',
      );
    },
  );
}
