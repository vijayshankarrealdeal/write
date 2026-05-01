import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import 'package:inkspacex/services/spell_check_service.dart';

/// Inline Quill attribute key used to paint the wavy red underline on
/// misspelled spans. `ignore` scope keeps it out of Quill's standard
/// formatting code paths; we still strip it via [stripSpellCheckErrors]
/// before any save/sync so it never lands in the persisted delta.
const String kSpellCheckErrorKey = 'spellcheck-error';

Attribute<bool?> spellCheckErrorAttribute({bool present = true}) =>
    Attribute<bool?>(kSpellCheckErrorKey, AttributeScope.ignore, present ? true : null);

/// Word/Google-Docs-style red wavy underline applied per misspelled span.
const TextStyle kSpellCheckErrorStyle = TextStyle(
  decoration: TextDecoration.underline,
  decorationStyle: TextDecorationStyle.wavy,
  decorationColor: Color(0xFFE53935),
  decorationThickness: 1.6,
);

/// Replace the current set of `spellcheck-error` spans on [controller] with
/// the spans implied by [issues]. We route the batched delta through
/// [QuillController.compose] (not [Document.compose]) because the editor's
/// repaint pipeline is driven by the controller's [ChangeNotifier] —
/// composing on the document alone updates the model but never repaints.
/// [ChangeSource.silent] keeps the autosave/scan listeners from treating
/// the decoration as a user edit (see filters in [EditorProvider.initEditor]
/// and [SpellCheckProvider._scheduleScan]).
void applySpellCheckErrors(
  QuillController controller,
  List<Misspelling> issues,
) {
  final doc = controller.document;
  final length = doc.length;
  if (length <= 1) return;

  // Existing decorated ranges in the live document.
  final existing = _collectErrorRanges(doc).toSet();
  // Ranges we want decorated after this call.
  final desired = <(int, int)>{};
  for (final m in issues) {
    if (m.start < 0 || m.length <= 0) continue;
    final end = m.start + m.length;
    if (end > length - 1) continue;
    desired.add((m.start, m.length));
  }

  // Only diff against the live state — touching ranges that are already
  // correctly decorated would emit overlapping clear+apply marks at the
  // same offset, and the second mark gets skipped by the cursor walk
  // below, accidentally wiping the underline.
  final toClear = existing.difference(desired);
  final toApply = desired.difference(existing);
  if (toClear.isEmpty && toApply.isEmpty) return;

  final marks = <_Mark>[];
  for (final r in toClear) {
    marks.add(_Mark(r.$1, r.$2, clear: true));
  }
  for (final r in toApply) {
    marks.add(_Mark(r.$1, r.$2, clear: false));
  }
  marks.sort((a, b) => a.start.compareTo(b.start));

  final batch = Delta();
  var cursor = 0;
  for (final mark in marks) {
    if (mark.start < cursor) continue;
    if (mark.start > cursor) {
      batch.retain(mark.start - cursor);
      cursor = mark.start;
    }
    batch.retain(mark.length, {
      kSpellCheckErrorKey: mark.clear ? null : true,
    });
    cursor += mark.length;
  }

  if (batch.isEmpty) return;
  controller.compose(batch, controller.selection, ChangeSource.silent);
}

/// Walks the document and returns `(start, length)` for every node that
/// currently carries the spell-check attribute. Used to clear stale
/// underlines before applying a fresh issues list.
List<(int, int)> _collectErrorRanges(Document doc) {
  final ranges = <(int, int)>[];
  final delta = doc.toDelta();
  var offset = 0;
  for (final op in delta.toList()) {
    final data = op.data;
    final len = op.length ?? 0;
    final attrs = op.attributes;
    if (data is String && attrs != null && attrs.containsKey(kSpellCheckErrorKey)) {
      ranges.add((offset, len));
    }
    offset += len;
  }
  return ranges;
}

/// Returns a copy of [delta] with the spell-check decoration attribute
/// removed from every op. Persisted/synced deltas must go through this so
/// transient UI marks never reach storage or the collab broadcast.
Delta stripSpellCheckErrors(Delta delta) {
  final out = Delta();
  for (final op in delta.toList()) {
    final attrs = op.attributes;
    Map<String, dynamic>? cleaned;
    if (attrs != null && attrs.containsKey(kSpellCheckErrorKey)) {
      cleaned = Map<String, dynamic>.from(attrs)..remove(kSpellCheckErrorKey);
      if (cleaned.isEmpty) cleaned = null;
    } else {
      cleaned = attrs;
    }
    final data = op.data;
    if (op.isInsert) {
      out.insert(data, cleaned);
    } else if (op.isRetain) {
      out.retain(op.length!, cleaned);
    } else if (op.isDelete) {
      out.delete(op.length!);
    }
  }
  return out;
}

class _Mark {
  _Mark(this.start, this.length, {required this.clear});
  final int start;
  final int length;
  final bool clear;
}
