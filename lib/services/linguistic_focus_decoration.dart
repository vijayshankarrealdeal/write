import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import 'package:inkspacex/services/linguistic_focus_service.dart';

/// Inline Quill attribute keys used to paint the linguistic-focus
/// overlay. Both live on the `ignore` scope so they never leak into
/// persisted deltas; we still strip them via [stripLinguisticAttrs]
/// before any save/sync as belt-and-braces.
///
/// Two attributes (not one with three states) keeps the
/// `customStyleBuilder` branch simple: present-and-true → highlight;
/// present-and-true → dim. A single tristate would have to encode
/// "absent vs. cleared", which Quill's silent compose handles
/// awkwardly.
const String kLinguisticHighlightKey = 'linguistic-highlight';
const String kLinguisticDimKey = 'linguistic-dim';

Attribute<String?> linguisticHighlightAttribute({String? className}) =>
    Attribute<String?>(
      kLinguisticHighlightKey,
      AttributeScope.ignore,
      className,
    );

Attribute<bool?> linguisticDimAttribute({bool present = true}) =>
    Attribute<bool?>(
      kLinguisticDimKey,
      AttributeScope.ignore,
      present ? true : null,
    );

/// Translucent backgrounds, one per class. Picked to read as a
/// sticky-note tint rather than an alarm — the user is reviewing
/// their prose, not being warned.
const Map<String, Color> kLinguisticHighlightColors = {
  LinguisticClass.dialogue: Color(0x66FFD580), // amber
  LinguisticClass.adverbs: Color(0x66FF8A80), // coral
  LinguisticClass.adjectives: Color(0x6680D8FF), // sky
  LinguisticClass.verbs: Color(0x66B9F6CA), // mint
  LinguisticClass.nouns: Color(0x66CE93D8), // lavender
};

/// Per-class underline decoration. Pairs with the background colour so
/// the overlay is still legible for users with colour-vision deficiency
/// — each class gets a structurally-different underline (solid,
/// dashed, dotted, wavy, double) on top of its tint, which is
/// recognisable by shape alone. Off / unknown classes get no
/// decoration so we don't underline arbitrary prose.
const Map<String, TextDecorationStyle> kLinguisticDecorationStyles = {
  LinguisticClass.dialogue: TextDecorationStyle.solid,
  LinguisticClass.adverbs: TextDecorationStyle.dashed,
  LinguisticClass.adjectives: TextDecorationStyle.dotted,
  LinguisticClass.verbs: TextDecorationStyle.wavy,
  LinguisticClass.nouns: TextDecorationStyle.double,
};

/// Style applied to a span carrying [kLinguisticHighlightKey]. Sets a
/// background colour and a class-specific underline so the overlay is
/// distinguishable by shape, not colour alone (the colourblind a11y
/// requirement). Original font colour, weight, and size from the
/// editor's `customStyles` block survive — we only add decoration.
TextStyle linguisticHighlightStyle(String? className) {
  if (className == null) return const TextStyle();
  final color = kLinguisticHighlightColors[className];
  final decorationStyle = kLinguisticDecorationStyles[className];
  return TextStyle(
    backgroundColor: color,
    decoration:
        decorationStyle == null ? null : TextDecoration.underline,
    decorationStyle: decorationStyle,
    decorationColor: color?.withValues(alpha: 1.0),
    decorationThickness: 1.4,
  );
}

/// Dimming style for non-matching text. Lowering the colour alpha
/// against the editor's normal text colour gives the "fade
/// everything else" effect the toggle UI advertises. We deliberately
/// don't touch backgroundColor here so paragraph styles still show.
const TextStyle kLinguisticDimStyle = TextStyle(
  color: Color(0x44000000), // ≈ 27% black; layered theme colour wins on dark
);

/// Replace the current set of linguistic-focus marks on [controller]
/// with a fresh layer derived from [highlightSpans] (ranges to
/// brighten) and the implied gaps (ranges to dim). Pass an empty
/// list to clear all decoration in one compose. Same pattern as
/// [applySpellCheckErrors] — we route the batched delta through
/// [QuillController.compose] (not [Document.compose]) so the editor
/// repaints, and use [ChangeSource.silent] so the autosave / scan
/// pipelines don't treat the cosmetic compose as a user edit.
void applyLinguisticFocus(
  QuillController controller, {
  required String? activeClass,
  required List<LinguisticSpan> highlightSpans,
}) {
  final doc = controller.document;
  final length = doc.length;
  if (length <= 1) {
    // Empty doc — only thing it might contain is stale marks. Clear.
    final clear = _clearAllDelta(doc);
    if (clear.isEmpty) return;
    controller.compose(clear, controller.selection, ChangeSource.silent);
    return;
  }

  // Existing decorated ranges.
  final existingHighlight = _collectRanges(doc, kLinguisticHighlightKey);
  final existingDim = _collectRanges(doc, kLinguisticDimKey);

  // Desired highlight ranges — clamp to the doc body (everything
  // before the trailing `\n` Quill always appends). Drop empty or
  // negative spans so a malformed backend response can't corrupt
  // the editor.
  final desiredHighlight = <(int, int)>[];
  for (final s in highlightSpans) {
    if (s.start < 0 || s.length <= 0) continue;
    final end = s.start + s.length;
    if (end > length - 1) continue;
    desiredHighlight.add((s.start, s.length));
  }
  desiredHighlight.sort((a, b) => a.$1.compareTo(b.$1));
  final mergedHighlight = _mergeRanges(desiredHighlight);

  // Dim is the complement of highlight when an active class is set,
  // and empty when no class is active (overlay is off — we want a
  // pristine editor).
  final desiredDim = activeClass == null
      ? const <(int, int)>[]
      : _complement(mergedHighlight, length - 1);

  final batch = Delta();
  // Walk the document once, deciding the desired attributes for each
  // codepoint in [0, length-1). We compose one retain op per change
  // boundary so the resulting Delta is as compact as possible.
  var cursor = 0;
  Map<String, dynamic>? pendingAttrs;
  var pendingStart = 0;

  void flush(int upTo) {
    final span = upTo - pendingStart;
    if (span <= 0) return;
    if (pendingAttrs == null) {
      // No attribute change in this run — emit a plain retain so
      // cursor positions stay aligned. We only emit if the run is
      // not at the doc start (Delta.retain(0) is illegal).
      batch.retain(span);
    } else {
      batch.retain(span, pendingAttrs);
    }
  }

  // Pre-build sorted highlight + dim range maps for O(N+M) walk.
  final highlightAt = <int, int>{}; // start -> end
  for (final r in mergedHighlight) {
    highlightAt[r.$1] = r.$1 + r.$2;
  }
  final dimAt = <int, int>{};
  for (final r in desiredDim) {
    dimAt[r.$1] = r.$1 + r.$2;
  }
  final existingHighlightSet = existingHighlight.toSet();
  final existingDimSet = existingDim.toSet();

  // Build position-indexed boolean arrays so we can compare desired
  // vs. existing per-character cheaply. For 200 KB of text this is
  // 400 KB of bools — fine.
  final body = length - 1;
  final desiredHighlightFlags = List<bool>.filled(body, false);
  for (final r in mergedHighlight) {
    for (var i = r.$1; i < r.$1 + r.$2 && i < body; i++) {
      desiredHighlightFlags[i] = true;
    }
  }
  final desiredDimFlags = List<bool>.filled(body, false);
  for (final r in desiredDim) {
    for (var i = r.$1; i < r.$1 + r.$2 && i < body; i++) {
      desiredDimFlags[i] = true;
    }
  }
  final existingHighlightFlags = List<bool>.filled(body, false);
  for (final r in existingHighlightSet) {
    for (var i = r.$1; i < r.$1 + r.$2 && i < body; i++) {
      existingHighlightFlags[i] = true;
    }
  }
  final existingDimFlags = List<bool>.filled(body, false);
  for (final r in existingDimSet) {
    for (var i = r.$1; i < r.$1 + r.$2 && i < body; i++) {
      existingDimFlags[i] = true;
    }
  }

  // Walk the body, grouping consecutive characters that need the
  // same compose attributes (set, clear, or no-op). Then emit one
  // retain per group so the final Delta is short and the cursor
  // doesn't move.
  Map<String, dynamic>? attrsAt(int i) {
    final wantsHighlight = desiredHighlightFlags[i];
    final wantsDim = desiredDimFlags[i];
    final hasHighlight = existingHighlightFlags[i];
    final hasDim = existingDimFlags[i];
    final out = <String, dynamic>{};
    if (wantsHighlight && !hasHighlight) {
      out[kLinguisticHighlightKey] = activeClass;
    } else if (!wantsHighlight && hasHighlight) {
      out[kLinguisticHighlightKey] = null;
    }
    if (wantsDim && !hasDim) {
      out[kLinguisticDimKey] = true;
    } else if (!wantsDim && hasDim) {
      out[kLinguisticDimKey] = null;
    }
    if (out.isEmpty) return null;
    return out;
  }

  Map<String, dynamic>? lastAttrs = attrsAt(0);
  pendingStart = 0;
  pendingAttrs = lastAttrs;
  for (var i = 1; i < body; i++) {
    final a = attrsAt(i);
    if (!_attrsEqual(a, lastAttrs)) {
      flush(i);
      pendingStart = i;
      pendingAttrs = a;
      lastAttrs = a;
    }
  }
  flush(body);
  cursor = body;

  if (cursor < length) {
    // Trail past any remainder (e.g. the final `\n`) without setting
    // attributes so we don't accidentally decorate it.
    batch.retain(length - cursor);
  }

  if (batch.isEmpty) return;
  // Skip composes that consist entirely of empty trailing retains —
  // those represent "no actual mark change" and would still trigger
  // a controller listener pulse without doing anything visible.
  final hasMeaningfulOp = batch.toList().any((op) {
    final attrs = op.attributes;
    return attrs != null && attrs.isNotEmpty;
  });
  if (!hasMeaningfulOp) return;

  controller.compose(batch, controller.selection, ChangeSource.silent);
}

bool _attrsEqual(Map<String, dynamic>? a, Map<String, dynamic>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == null && b == null;
  if (a.length != b.length) return false;
  for (final k in a.keys) {
    if (!b.containsKey(k)) return false;
    if (a[k] != b[k]) return false;
  }
  return true;
}

/// Walk [doc] and return every `(start, length)` whose op carries
/// the [attrKey] attribute.
List<(int, int)> _collectRanges(Document doc, String attrKey) {
  final ranges = <(int, int)>[];
  final delta = doc.toDelta();
  var offset = 0;
  for (final op in delta.toList()) {
    final data = op.data;
    final len = op.length ?? 0;
    final attrs = op.attributes;
    if (data is String &&
        attrs != null &&
        attrs.containsKey(attrKey) &&
        attrs[attrKey] != null) {
      ranges.add((offset, len));
    }
    offset += len;
  }
  return ranges;
}

List<(int, int)> _mergeRanges(List<(int, int)> ranges) {
  if (ranges.isEmpty) return ranges;
  final out = <(int, int)>[ranges.first];
  for (final r in ranges.skip(1)) {
    final last = out.last;
    final lastEnd = last.$1 + last.$2;
    if (r.$1 <= lastEnd) {
      final newEnd = lastEnd > r.$1 + r.$2 ? lastEnd : r.$1 + r.$2;
      out[out.length - 1] = (last.$1, newEnd - last.$1);
    } else {
      out.add(r);
    }
  }
  return out;
}

/// Return all gaps between [highlight] ranges within `[0, end)`. Used
/// to derive the dim layer as the complement of the highlight layer.
List<(int, int)> _complement(List<(int, int)> highlight, int end) {
  if (end <= 0) return const [];
  if (highlight.isEmpty) return [(0, end)];
  final out = <(int, int)>[];
  var cursor = 0;
  for (final r in highlight) {
    if (r.$1 > cursor) {
      out.add((cursor, r.$1 - cursor));
    }
    final rEnd = r.$1 + r.$2;
    if (rEnd > cursor) cursor = rEnd;
  }
  if (cursor < end) {
    out.add((cursor, end - cursor));
  }
  return out;
}

/// Build a Delta that clears any linguistic-focus marks present in
/// [doc]. Used on empty documents (where the main path's body-walk
/// can't run) and on toggle-off.
Delta _clearAllDelta(Document doc) {
  final batch = Delta();
  final delta = doc.toDelta();
  var offset = 0;
  var cursor = 0;
  for (final op in delta.toList()) {
    final len = op.length ?? 0;
    final attrs = op.attributes;
    final hasHighlight =
        attrs != null && attrs.containsKey(kLinguisticHighlightKey);
    final hasDim = attrs != null && attrs.containsKey(kLinguisticDimKey);
    if (op.data is String && (hasHighlight || hasDim)) {
      if (offset > cursor) {
        batch.retain(offset - cursor);
        cursor = offset;
      }
      final clearAttrs = <String, dynamic>{
        if (hasHighlight) kLinguisticHighlightKey: null,
        if (hasDim) kLinguisticDimKey: null,
      };
      batch.retain(len, clearAttrs);
      cursor += len;
    }
    offset += len;
  }
  return batch;
}

/// Returns a copy of [delta] with the linguistic-focus attributes
/// removed from every op. Persisted/synced deltas must go through
/// this so transient overlay marks never reach storage.
Delta stripLinguisticAttrs(Delta delta) {
  final out = Delta();
  for (final op in delta.toList()) {
    final attrs = op.attributes;
    Map<String, dynamic>? cleaned;
    if (attrs != null &&
        (attrs.containsKey(kLinguisticHighlightKey) ||
            attrs.containsKey(kLinguisticDimKey))) {
      cleaned = Map<String, dynamic>.from(attrs)
        ..remove(kLinguisticHighlightKey)
        ..remove(kLinguisticDimKey);
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
