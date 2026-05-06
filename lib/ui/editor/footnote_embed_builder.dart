import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:inkspacex/models/footnote_model.dart';

/// Custom Quill embed for inline footnote markers.
///
/// The marker stores a stable `id` (e.g. `fn-9k2x`) — never the visible
/// number. The visible number is derived from the section's footnote
/// list at render time, so reorder/delete never needs to rewrite the
/// Quill delta. If the id can't be resolved (footnote was deleted while
/// the inline marker was left dangling) we render `?` so the author
/// notices and can clean up.
class FootnoteBlockEmbed extends BlockEmbed {
  const FootnoteBlockEmbed(String id) : super(footnoteType, id);

  static const String footnoteType = 'footnote';

  static FootnoteBlockEmbed of(String id) => FootnoteBlockEmbed(id);
}

/// Renders the inline `¹², ³` superscript marker for a footnote embed.
/// On tap, [onTapMarker] is invoked with the embed id so the host page
/// can scroll the footnotes panel / inspector to the matching entry.
class FootnoteEmbedBuilder extends EmbedBuilder {
  FootnoteEmbedBuilder({
    required this.footnotesProvider,
    this.onTapMarker,
    this.readOnly = false,
  });

  /// Called every build to fetch the current ordered list of footnotes
  /// for the active section. We don't cache it here because the editor
  /// rebuilds on selection changes anyway, and the list of footnotes
  /// can mutate independently of the delta.
  final List<FootnoteModel> Function() footnotesProvider;

  /// Optional click handler. If null, the marker still renders but is
  /// not interactive — used by read-only previews (e.g. scrivenings
  /// view, publish preview).
  final void Function(String footnoteId)? onTapMarker;

  final bool readOnly;

  @override
  String get key => FootnoteBlockEmbed.footnoteType;

  // Inline embed — must NOT be expanded, otherwise the line height
  // stretches to fit the embed and we lose the cursor position next to
  // it. Footnote markers are always single-character superscripts.
  @override
  bool get expanded => false;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final raw = embedContext.node.value.data;
    final id = raw is String ? raw : raw?.toString() ?? '';
    final footnotes = footnotesProvider();
    final idx = footnotes.indexWhere((f) => f.id == id);
    final number = idx >= 0 ? idx + 1 : null;
    final label = number != null ? toSuperscript(number) : '?';
    return _FootnoteMarker(
      label: label,
      tooltip: number != null
          ? 'Footnote $number${footnotes[idx].text.isNotEmpty ? ': ${_preview(footnotes[idx].text)}' : ''}'
          : 'Footnote (deleted)',
      onTap: (readOnly || onTapMarker == null) ? null : () => onTapMarker!(id),
    );
  }

  static String _preview(String text) {
    final t = text.trim().replaceAll('\n', ' ');
    if (t.length <= 60) return t;
    return '${t.substring(0, 60)}…';
  }
}

class _FootnoteMarker extends StatelessWidget {
  const _FootnoteMarker({
    required this.label,
    required this.tooltip,
    this.onTap,
  });

  final String label;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF93B4F5) : const Color(0xFF4A6CF7);
    final marker = Padding(
      padding: const EdgeInsets.only(left: 1, right: 1),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: accent,
          height: 1.0,
        ),
      ),
    );
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: onTap == null
          ? marker
          : MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: marker,
              ),
            ),
    );
  }
}

/// Map an integer (1..) to a Unicode superscript string. We prefer
/// Unicode codepoints over CSS-style superscript so the marker copies
/// cleanly into plain text export.
String toSuperscript(int n) {
  const map = {
    '0': '⁰',
    '1': '¹',
    '2': '²',
    '3': '³',
    '4': '⁴',
    '5': '⁵',
    '6': '⁶',
    '7': '⁷',
    '8': '⁸',
    '9': '⁹',
    '-': '⁻',
  };
  final s = n.toString();
  final buf = StringBuffer();
  for (final ch in s.split('')) {
    buf.write(map[ch] ?? ch);
  }
  return buf.toString();
}
