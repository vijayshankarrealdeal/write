import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/linguistic_focus_provider.dart';
import 'package:inkspacex/services/linguistic_focus_decoration.dart';
import 'package:inkspacex/services/linguistic_focus_service.dart';

/// Status-bar chip that surfaces the current Linguistic Focus state
/// and opens the class picker on tap.
///
/// Off  → faint "Focus" label
/// On   → highlight-colour swatch + class label + match count
///
/// All five canonical classes plus Off live in the popover. Lives
/// next to the spell-check chip in the editor's status bar — same
/// visual rhythm as the other ambient indicators (typewriter, save,
/// session word count).
class LinguisticFocusChip extends StatelessWidget {
  const LinguisticFocusChip({
    super.key,
    this.textColor,
    this.isDark = false,
  });

  final Color? textColor;
  final bool isDark;

  void _openPicker(BuildContext context) {
    final provider = context.read<LinguisticFocusProvider>();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => LinguisticFocusSheet(provider: provider),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<LinguisticFocusProvider>(
      builder: (context, lp, _) {
        final c = lp.activeClass;
        final mutedColor = isDark
            ? Colors.white.withValues(alpha: 0.45)
            : Colors.black.withValues(alpha: 0.45);
        final activeColor = c == null
            ? mutedColor
            : (kLinguisticHighlightColors[c] ?? mutedColor)
                .withValues(alpha: 1.0);
        final IconData icon;
        final String label;
        if (c == null) {
          icon = CupertinoIcons.eye;
          label = 'Focus';
        } else if (lp.scanning && !lp.hasScanned) {
          icon = CupertinoIcons.arrow_2_circlepath;
          label = '${LinguisticClass.label(c)}…';
        } else {
          icon = CupertinoIcons.eye_fill;
          label = '${LinguisticClass.label(c)} · ${lp.matchCount}';
        }
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => _openPicker(context),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 11, color: activeColor),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: activeColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Bottom-sheet picker — six radio rows (one per class plus Off).
/// Selecting a row immediately mutates the provider and closes the
/// sheet so the user is back on the editor with the new highlight
/// applied. The radio rather than a chip group keeps it screen-
/// readable on mobile and one-thumb tappable.
class LinguisticFocusSheet extends StatelessWidget {
  const LinguisticFocusSheet({
    super.key,
    required this.provider,
  });

  final LinguisticFocusProvider provider;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0C0C0C) : Colors.white;
    final fg = isDark ? Colors.white : const Color(0xFF1A1A1F);
    final mutedFg = fg.withValues(alpha: 0.55);
    final divider = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: ListenableBuilder(
          listenable: provider,
          builder: (context, _) {
            // Wrap in a scroll view so the sheet stays usable on
            // small viewports / tall keyboards — six radio rows plus
            // header is enough to overflow a phone in landscape.
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(top: 8, bottom: 12),
                    decoration: BoxDecoration(
                      color: fg.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.eye, size: 18, color: fg),
                      const SizedBox(width: 10),
                      Text(
                        'Linguistic Focus',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: fg,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    'Highlight one part-of-speech at a time to spot '
                    'pacing or style issues. Everything else fades.',
                    style: TextStyle(fontSize: 12, color: mutedFg),
                  ),
                ),
                Divider(color: divider, height: 1),
                if (provider.posUnavailable)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.exclamationmark_circle,
                            size: 13, color: mutedFg),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'POS tagging is unavailable on this server. '
                            'Dialogue still works.',
                            style: TextStyle(
                              fontSize: 11,
                              color: mutedFg,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                _OffRow(
                  selected: provider.activeClass == null,
                  fg: fg,
                  mutedFg: mutedFg,
                  onTap: () async {
                    await provider.setActiveClass(null);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
                for (final cls in LinguisticClass.all)
                  _ClassRow(
                    className: cls,
                    selected: provider.activeClass == cls,
                    fg: fg,
                    mutedFg: mutedFg,
                    onTap: () async {
                      await provider.setActiveClass(cls);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
            );
          },
        ),
      ),
    );
  }
}

class _OffRow extends StatelessWidget {
  const _OffRow({
    required this.selected,
    required this.fg,
    required this.mutedFg,
    required this.onTap,
  });

  final bool selected;
  final Color fg;
  final Color mutedFg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            _RadioDot(selected: selected, color: fg),
            const SizedBox(width: 14),
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: mutedFg.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: mutedFg.withValues(alpha: 0.4)),
              ),
            ),
            const SizedBox(width: 14),
            Text(
              'Off',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClassRow extends StatelessWidget {
  const _ClassRow({
    required this.className,
    required this.selected,
    required this.fg,
    required this.mutedFg,
    required this.onTap,
  });

  final String className;
  final bool selected;
  final Color fg;
  final Color mutedFg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = kLinguisticHighlightColors[className] ?? mutedFg;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            _RadioDot(selected: selected, color: fg),
            const SizedBox(width: 14),
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 14),
            Text(
              LinguisticClass.label(className),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RadioDot extends StatelessWidget {
  const _RadioDot({required this.selected, required this.color});

  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? color : color.withValues(alpha: 0.35),
          width: 1.6,
        ),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                ),
              ),
            )
          : null,
    );
  }
}
