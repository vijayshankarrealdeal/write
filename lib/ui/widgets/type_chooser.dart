import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/ui/utilities/responsive_layout.dart';
import 'package:inkspacex/ui/utilities/writing_type_style.dart';

class TypeChooser extends StatelessWidget {
  final WritingType? selected;
  final ValueChanged<WritingType> onSelect;
  final bool isDark;
  final bool compact;

  const TypeChooser({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.isDark,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isMobile = Breakpoints.isMobile(screenWidth);
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final mutedColor = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.5);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);
    final surfaceColor = isDark ? const Color(0xFF141414) : Colors.white;
    final useCompact = compact || isMobile;

    final cards = WritingType.values.map((t) {
      final style = styleFor(t);
      return TypeCard(
        type: t,
        style: style,
        isSelected: selected == t,
        onTap: () => onSelect(t),
        isDark: isDark,
        compact: useCompact,
        textColor: textColor,
        mutedColor: mutedColor,
        borderColor: borderColor,
        surfaceColor: surfaceColor,
      );
    }).toList();

    if (isMobile) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth;
          const gap = 8.0;
          final cardWidth = (available - gap) / 2;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: cards
                .map((c) => SizedBox(width: cardWidth, child: c))
                .toList(),
          );
        },
      );
    }

    return Row(
      children: [
        for (int i = 0; i < cards.length; i++) ...[
          Expanded(child: cards[i]),
          if (i != cards.length - 1) const SizedBox(width: 10),
        ],
      ],
    );
  }
}

class TypeCard extends StatefulWidget {
  final WritingType type;
  final WritingTypeStyle style;
  final bool isSelected;
  final VoidCallback onTap;
  final bool isDark;
  final bool compact;
  final Color textColor;
  final Color mutedColor;
  final Color borderColor;
  final Color surfaceColor;

  const TypeCard({
    super.key,
    required this.type,
    required this.style,
    required this.isSelected,
    required this.onTap,
    required this.isDark,
    this.compact = false,
    required this.textColor,
    required this.mutedColor,
    required this.borderColor,
    required this.surfaceColor,
  });

  @override
  State<TypeCard> createState() => _TypeCardState();
}

class _TypeCardState extends State<TypeCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.style.accent;
    final selected = widget.isSelected;
    final active = selected || _hovering;

    final bg = selected
        ? accent.withValues(alpha: widget.isDark ? 0.12 : 0.08)
        : widget.surfaceColor;
    final border = selected
        ? accent.withValues(alpha: 0.6)
        : active
            ? accent.withValues(alpha: 0.28)
            : widget.borderColor;

    final compact = widget.compact;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          height: compact ? 88 : 172,
          padding: EdgeInsets.all(compact ? 10 : 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(compact ? 12 : 16),
            border: Border.all(
              color: border,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: EdgeInsets.all(compact ? 6 : 9),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: selected ? 0.22 : 0.12),
                  borderRadius: BorderRadius.circular(compact ? 8 : 10),
                ),
                child: Icon(
                  widget.style.icon,
                  color: accent,
                  size: compact ? 14 : 18,
                ),
              ),
              const Spacer(),
              Text(
                widget.type.displayName,
                style: GoogleFonts.inter(
                  fontSize: compact ? 14 : 20,
                  fontWeight: FontWeight.w700,
                  color: widget.textColor,
                  height: 1.1,
                  letterSpacing: -0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: compact ? 2 : 6),
              Text(
                widget.style.tagline,
                style: GoogleFonts.inter(
                  fontSize: compact ? 11 : 12,
                  color: widget.mutedColor,
                  height: 1.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
