import 'dart:convert';
import 'dart:math' as math;

import 'package:inkspacex/models/footnote_model.dart';
import 'package:inkspacex/ui/editor/footnote_embed_builder.dart';

/// Pure helpers around the footnote list/delta interaction.
///
/// Kept separate from the provider and the embed widget so the logic is
/// trivially unit-testable: nothing in here touches Flutter widgets, a
/// QuillController, Hive, or the network. Anything inside this service
/// can be exercised from a `flutter_test` group in milliseconds.
class FootnotesService {
  static final _rand = math.Random();

  /// Mint a stable id for a fresh footnote. We avoid raw UUIDs so the
  /// id stays compact in the Quill delta JSON (which can be megabytes
  /// in long chapters), but the entropy is sufficient to avoid
  /// collisions inside one section's footnote list.
  static String newId({DateTime? now, math.Random? rand}) {
    final r = rand ?? _rand;
    final ms = (now ?? DateTime.now()).microsecondsSinceEpoch;
    final suffix = r.nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return 'fn-${ms.toRadixString(36)}-$suffix';
  }

  /// Reorder [footnotes] so that the entries appear in the same order as
  /// their inline markers in [delta]. Footnotes whose markers don't appear
  /// (orphans, kept around so the user can adopt them later) are appended
  /// in their original list order at the end. Any embed id that doesn't
  /// resolve to a footnote in [footnotes] is dropped — we don't invent
  /// entries for unknown ids, the inspector renders them as deleted.
  static List<FootnoteModel> sortByDeltaOrder(
    List<FootnoteModel> footnotes,
    List<dynamic> delta,
  ) {
    final byId = {for (final f in footnotes) f.id: f};
    final seen = <String>{};
    final ordered = <FootnoteModel>[];
    for (final id in deltaFootnoteIds(delta)) {
      if (seen.contains(id)) continue;
      seen.add(id);
      final f = byId[id];
      if (f != null) ordered.add(f);
    }
    for (final f in footnotes) {
      if (!seen.contains(f.id)) ordered.add(f);
    }
    return ordered;
  }

  /// Walk a Quill delta and yield every footnote embed id, in document
  /// order. Multiple references to the same footnote (a writer cited the
  /// same source twice) are returned each time; callers de-dupe if they
  /// need a unique set.
  static List<String> deltaFootnoteIds(List<dynamic> delta) {
    final out = <String>[];
    for (final op in delta) {
      if (op is! Map) continue;
      final insert = op['insert'];
      if (insert is Map) {
        final v = insert[FootnoteBlockEmbed.footnoteType];
        if (v is String && v.isNotEmpty) {
          out.add(v);
        }
      }
    }
    return out;
  }

  /// Parse a section's `content` (a JSON Quill delta string) and return
  /// the in-document footnote ids. Returns an empty list if the content
  /// is not a parseable delta — the editor stores `''` for empty new
  /// sections.
  static List<String> idsFromContent(String content) {
    if (content.isEmpty) return const [];
    try {
      final parsed = jsonDecode(content);
      if (parsed is List) return deltaFootnoteIds(parsed);
    } catch (_) {
      return const [];
    }
    return const [];
  }

  /// Drop entries from [footnotes] whose id has no matching marker in
  /// [delta]. Used by the publish path so endnote rendering doesn't list
  /// footnotes whose marker the author already deleted.
  static List<FootnoteModel> dropOrphans(
    List<FootnoteModel> footnotes,
    List<dynamic> delta,
  ) {
    final live = deltaFootnoteIds(delta).toSet();
    return [for (final f in footnotes) if (live.contains(f.id)) f];
  }

  /// Build an "endnotes" Quill delta tail that can be appended to a
  /// section's body for read-only render in publish output. The tail is
  /// rendered as: a divider line, a `Footnotes` h3, then one paragraph
  /// per footnote prefixed with its visible number.
  static List<Map<String, dynamic>> renderEndnotesDelta(
    List<FootnoteModel> footnotes, {
    String heading = 'Footnotes',
  }) {
    if (footnotes.isEmpty) return const [];
    final ops = <Map<String, dynamic>>[];
    // Trailing newline before the heading so the heading attribute
    // applies to a fresh paragraph rather than swallowing the previous
    // line.
    ops.add(<String, dynamic>{'insert': '\n'});
    ops.add(<String, dynamic>{'insert': heading});
    ops.add(<String, dynamic>{
      'insert': '\n',
      'attributes': {'header': 3},
    });
    for (var i = 0; i < footnotes.length; i++) {
      final n = i + 1;
      final superscript = toSuperscript(n);
      ops.add(<String, dynamic>{'insert': '$superscript '});
      ops.add(<String, dynamic>{'insert': footnotes[i].text});
      ops.add(<String, dynamic>{'insert': '\n'});
    }
    return ops;
  }

  /// Render the footnotes section as plain text (e.g. for share intents
  /// that can't carry a Quill delta).
  static String renderEndnotesText(
    List<FootnoteModel> footnotes, {
    String heading = 'Footnotes',
  }) {
    if (footnotes.isEmpty) return '';
    final buf = StringBuffer();
    buf.writeln();
    buf.writeln(heading);
    for (var i = 0; i < footnotes.length; i++) {
      buf.writeln('${toSuperscript(i + 1)} ${footnotes[i].text}');
    }
    return buf.toString();
  }
}
