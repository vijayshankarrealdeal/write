import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Four-way segmented control. The first three mirror Scrivener's
/// ⌘1 / ⌘2 / ⌘3; `scrivenings` is the continuous-scroll view of every
/// publishable section in the active book (read-only in v1; click any
/// section's pencil to jump back to Draft mode focused there).
enum EditorViewMode { draft, cards, outline, scrivenings }

extension EditorViewModeLabel on EditorViewMode {
  String get label {
    switch (this) {
      case EditorViewMode.draft:
        return 'Draft';
      case EditorViewMode.cards:
        return 'Cards';
      case EditorViewMode.outline:
        return 'Outline';
      case EditorViewMode.scrivenings:
        return 'All';
    }
  }

  IconData get icon {
    switch (this) {
      case EditorViewMode.draft:
        return CupertinoIcons.text_alignleft;
      case EditorViewMode.cards:
        return CupertinoIcons.square_grid_2x2;
      case EditorViewMode.outline:
        return CupertinoIcons.list_bullet;
      case EditorViewMode.scrivenings:
        return CupertinoIcons.doc_text_viewfinder;
    }
  }
}

class ViewSwitcher extends StatelessWidget {
  const ViewSwitcher({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final EditorViewMode mode;
  final ValueChanged<EditorViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = theme.textTheme.bodyMedium?.color ?? Colors.black;
    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in EditorViewMode.values)
            _segment(textColor, isDark, m),
        ],
      ),
    );
  }

  Widget _segment(Color textColor, bool isDark, EditorViewMode m) {
    final selected = m == mode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Material(
        color: selected
            ? (isDark ? Colors.white.withValues(alpha: 0.12) : Colors.white)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => onChanged(m),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(m.icon,
                    size: 14,
                    color: textColor
                        .withValues(alpha: selected ? 1.0 : 0.55)),
                const SizedBox(width: 6),
                Text(
                  m.label,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w500,
                    color: textColor
                        .withValues(alpha: selected ? 1.0 : 0.65),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
