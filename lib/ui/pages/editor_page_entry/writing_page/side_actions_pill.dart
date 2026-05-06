import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class SideActionsPill extends StatelessWidget {
  const SideActionsPill({
    super.key,
    required this.isDark,
    required this.outlineActive,
    required this.focusActive,
    required this.annotationsActive,
    required this.annotationCount,
    required this.onAI,
    required this.onPrompt,
    required this.onToggleOutline,
    required this.onToggleFocus,
    required this.onToggleAnnotations,
    required this.onVersionHistory,
    this.inspectorActive = false,
    this.onToggleInspector,
    this.onAddBookmark,
    this.bookmarkCount = 0,
  });

  final bool isDark;
  final bool outlineActive;
  final bool focusActive;
  final bool annotationsActive;
  final int annotationCount;
  final bool inspectorActive;
  final VoidCallback onAI;
  final VoidCallback onPrompt;
  final VoidCallback onToggleOutline;
  final VoidCallback onToggleFocus;
  final VoidCallback onToggleAnnotations;
  final VoidCallback onVersionHistory;
  final VoidCallback? onToggleInspector;

  /// Add an author bookmark at the current cursor position. Pill button
  /// is hidden if null. Long-press semantics live on the editor itself —
  /// this is the discoverable affordance for users who don't know
  /// ⌘⇧B.
  final VoidCallback? onAddBookmark;
  final int bookmarkCount;

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xFF1F2126) : Colors.white;
    final fg = isDark ? Colors.white : const Color(0xFF1A1A1F);
    final accent =
        isDark ? const Color(0xFF93B4F5) : const Color(0xFF4A6CF7);
    final activeBg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFFEFF3FE);
    final border = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.08);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
            blurRadius: 24,
            spreadRadius: -6,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SidePillButton(
            icon: CupertinoIcons.wand_stars,
            tooltip: 'AI assist',
            color: accent,
            activeBg: activeBg,
            highlight: true,
            onTap: onAI,
          ),
          _SidePillButton(
            icon: CupertinoIcons.lightbulb,
            tooltip: 'Writing prompt',
            color: Colors.amber.withValues(alpha: 0.85),
            activeBg: activeBg,
            onTap: onPrompt,
          ),
          _SidePillButton(
            icon: CupertinoIcons.list_bullet_indent,
            tooltip: outlineActive ? 'Hide outline' : 'Show outline',
            color: outlineActive ? accent : fg,
            activeBg: activeBg,
            active: outlineActive,
            onTap: onToggleOutline,
          ),
          _SidePillButton(
            icon: CupertinoIcons.chat_bubble_text,
            tooltip: annotationsActive
                ? 'Hide comments'
                : (annotationCount > 0
                    ? 'Comments ($annotationCount)'
                    : 'Comments'),
            color: annotationsActive ? accent : fg,
            activeBg: activeBg,
            active: annotationsActive,
            badgeCount: annotationCount,
            onTap: onToggleAnnotations,
          ),
          _SidePillButton(
            icon: CupertinoIcons.clock,
            tooltip: 'Version history',
            color: fg,
            activeBg: activeBg,
            onTap: onVersionHistory,
          ),
          if (onToggleInspector != null)
            _SidePillButton(
              icon: CupertinoIcons.info,
              tooltip:
                  inspectorActive ? 'Hide inspector' : 'Inspector (synopsis, notes)',
              color: inspectorActive ? accent : fg,
              activeBg: activeBg,
              active: inspectorActive,
              onTap: onToggleInspector!,
            ),
          if (onAddBookmark != null)
            _SidePillButton(
              icon: CupertinoIcons.bookmark,
              tooltip: bookmarkCount > 0
                  ? 'Add bookmark (⌘⇧B) — $bookmarkCount in this section'
                  : 'Add bookmark (⌘⇧B)',
              color: fg,
              activeBg: activeBg,
              badgeCount: bookmarkCount,
              onTap: onAddBookmark!,
            ),
          _SidePillButton(
            icon: CupertinoIcons.eye_slash,
            tooltip: focusActive ? 'Exit focus mode' : 'Focus mode',
            color: focusActive ? accent : fg,
            activeBg: activeBg,
            active: focusActive,
            onTap: onToggleFocus,
          ),
        ],
      ),
    );
  }
}

class _SidePillButton extends StatefulWidget {
  const _SidePillButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.activeBg,
    required this.onTap,
    this.active = false,
    this.highlight = false,
    this.badgeCount = 0,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final Color activeBg;
  final VoidCallback onTap;
  final bool active;
  final bool highlight;
  final int badgeCount;

  @override
  State<_SidePillButton> createState() => _SidePillButtonState();
}

class _SidePillButtonState extends State<_SidePillButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final showActiveBg = widget.active || _hover;
    return Tooltip(
      message: widget.tooltip,
      preferBelow: false,
      waitDuration: const Duration(milliseconds: 250),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            width: 38,
            height: 38,
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: showActiveBg ? widget.activeBg : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Icon(widget.icon, size: 17, color: widget.color),
                if (widget.badgeCount > 0)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      constraints:
                          const BoxConstraints(minWidth: 14, minHeight: 14),
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE26A4A),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        widget.badgeCount > 9
                            ? '9+'
                            : widget.badgeCount.toString(),
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 1,
                        ),
                      ),
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
