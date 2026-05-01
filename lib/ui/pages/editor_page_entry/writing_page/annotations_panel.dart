import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/models/editor_annotation_model.dart';
import 'package:inkspacex/provider/annotation_provider.dart';

// ── Annotations side panel ──
//
// A right-edge panel listing every annotation on the current section.
// Click a row to jump to its anchor in the document. Resolved entries
// fade and orphaned entries (anchor lost) sit at the bottom.
class AnnotationsPanel extends StatelessWidget {
  const AnnotationsPanel({
    super.key,
    required this.isDark,
    required this.textColor,
    required this.borderColor,
    required this.surfaceColor,
    required this.onJump,
    required this.onResolveToggle,
    required this.onDelete,
    required this.onClose,
  });

  final bool isDark;
  final Color textColor;
  final Color borderColor;
  final Color surfaceColor;
  final void Function(EditorAnnotation) onJump;
  final void Function(EditorAnnotation) onResolveToggle;
  final void Function(EditorAnnotation) onDelete;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ann = context.watch<AnnotationProvider>();
    final mutedFg = textColor.withValues(alpha: 0.55);
    final items = [...ann.annotations];
    items.sort((a, b) {
      // Orphaned to the bottom; resolved below open; otherwise newest first.
      if (a.orphaned != b.orphaned) return a.orphaned ? 1 : -1;
      if (a.resolved != b.resolved) return a.resolved ? 1 : -1;
      return b.createdAt.compareTo(a.createdAt);
    });

    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: surfaceColor,
        border: Border(left: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            child: Row(
              children: [
                Icon(CupertinoIcons.chat_bubble_text,
                    size: 16, color: textColor.withValues(alpha: 0.85)),
                const SizedBox(width: 8),
                Text(
                  'Comments',
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: textColor),
                ),
                const SizedBox(width: 6),
                Text(
                  '${items.length}',
                  style: GoogleFonts.inter(fontSize: 12, color: mutedFg),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Hide',
                  icon: Icon(CupertinoIcons.xmark,
                      size: 14, color: mutedFg),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Divider(color: borderColor, height: 1),
          Expanded(
            child: items.isEmpty
                ? _emptyState(mutedFg)
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: items.length,
                    separatorBuilder: (_, _) =>
                        Divider(color: borderColor, height: 1),
                    itemBuilder: (_, i) {
                      final a = items[i];
                      return _row(a, mutedFg);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(Color mutedFg) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Select text and click the comment icon to add a margin note.',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(fontSize: 12, color: mutedFg, height: 1.45),
        ),
      ),
    );
  }

  Widget _row(EditorAnnotation a, Color mutedFg) {
    final fadedSnippet = a.anchoredText.length > 80
        ? '${a.anchoredText.substring(0, 80)}…'
        : a.anchoredText;
    final fg = a.resolved || a.orphaned
        ? textColor.withValues(alpha: 0.45)
        : textColor;
    final tag = a.orphaned
        ? 'orphaned'
        : (a.resolved ? 'resolved' : null);
    return InkWell(
      onTap: a.orphaned ? null : () => onJump(a),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    a.authorName.isEmpty ? 'You' : a.authorName,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ),
                if (tag != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: mutedFg.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(tag,
                        style: GoogleFonts.inter(
                            fontSize: 10, color: mutedFg)),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  iconSize: 14,
                  padding: EdgeInsets.zero,
                  onSelected: (v) {
                    if (v == 'resolve') onResolveToggle(a);
                    if (v == 'delete') onDelete(a);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'resolve',
                      child: Text(a.resolved ? 'Reopen' : 'Resolve',
                          style: GoogleFonts.inter(fontSize: 12)),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete',
                          style: GoogleFonts.inter(
                              fontSize: 12, color: Colors.redAccent)),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: mutedFg.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
                border: Border(
                  left: BorderSide(
                      color: const Color(0xFFFFC857).withValues(alpha: 0.7),
                      width: 2),
                ),
              ),
              child: Text(
                fadedSnippet,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: mutedFg,
                  fontStyle: FontStyle.italic,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              a.body,
              style: GoogleFonts.inter(
                fontSize: 12.5,
                color: fg,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
