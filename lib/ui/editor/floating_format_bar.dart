import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';

/// A compact format bar that appears at the top of the editor area
/// whenever there is a non-collapsed text selection.
///
/// Word's "mini toolbar" pattern: instead of forcing the user to fish
/// through the main ribbon for the common format toggles, the most-used
/// actions float into reach the moment text is highlighted.
class FloatingFormatBar extends StatefulWidget {
  const FloatingFormatBar({
    super.key,
    required this.controller,
    required this.isDark,
    required this.onOpenLink,
  });

  final QuillController controller;
  final bool isDark;
  final VoidCallback onOpenLink;

  @override
  State<FloatingFormatBar> createState() => _FloatingFormatBarState();
}

class _FloatingFormatBarState extends State<FloatingFormatBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.25),
      end: Offset.zero,
    ).animate(_fade);
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _anim.dispose();
    super.dispose();
  }

  void _onChange() {
    final sel = widget.controller.selection;
    final shouldShow = sel.isValid && !sel.isCollapsed;
    if (shouldShow == _visible) return;
    setState(() => _visible = shouldShow);
    if (shouldShow) {
      _anim.forward();
    } else {
      _anim.reverse();
    }
  }

  bool _isActive(Attribute attr) =>
      widget.controller.getSelectionStyle().attributes.containsKey(attr.key);

  void _toggle(Attribute attr) {
    final active = _isActive(attr);
    widget.controller
        .formatSelection(active ? Attribute.clone(attr, null) : attr);
    setState(() {});
  }

  void _applyHeader(int? level) {
    final attr = level == null
        ? Attribute.clone(Attribute.header, null)
        : level == 1
            ? Attribute.h1
            : level == 2
                ? Attribute.h2
                : Attribute.h3;
    widget.controller.formatSelection(attr);
    setState(() {});
  }

  int? _currentHeader() {
    final v =
        widget.controller.getSelectionStyle().attributes[Attribute.header.key];
    final raw = v?.value;
    if (raw is int) return raw;
    return null;
  }

  bool get _hasLink =>
      widget.controller.getSelectionStyle().attributes
          .containsKey(Attribute.link.key);

  @override
  Widget build(BuildContext context) {
    if (!_visible && _anim.isDismissed) return const SizedBox.shrink();

    final isDark = widget.isDark;
    final bg = isDark ? const Color(0xFF1F2126) : Colors.white;
    final fg = isDark ? Colors.white : const Color(0xFF1A1A1F);
    final accent =
        isDark ? const Color(0xFF93B4F5) : const Color(0xFF4A6CF7);
    final activeBg = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : const Color(0xFFE3EBFB);
    final border = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);

    final header = _currentHeader();

    return SlideTransition(
      position: _slide,
      child: FadeTransition(
        opacity: _fade,
        child: Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.10),
                blurRadius: 18,
                spreadRadius: -4,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _miniBtn(Icons.format_bold, 'Bold',
                  active: _isActive(Attribute.bold),
                  fg: fg, accent: accent, activeBg: activeBg,
                  onTap: () => _toggle(Attribute.bold)),
              _miniBtn(Icons.format_italic, 'Italic',
                  active: _isActive(Attribute.italic),
                  fg: fg, accent: accent, activeBg: activeBg,
                  onTap: () => _toggle(Attribute.italic)),
              _miniBtn(Icons.format_underline, 'Underline',
                  active: _isActive(Attribute.underline),
                  fg: fg, accent: accent, activeBg: activeBg,
                  onTap: () => _toggle(Attribute.underline)),
              _miniBtn(Icons.format_strikethrough, 'Strikethrough',
                  active: _isActive(Attribute.strikeThrough),
                  fg: fg, accent: accent, activeBg: activeBg,
                  onTap: () => _toggle(Attribute.strikeThrough)),
              _vDivider(border),
              _headerPill('H1', 1, header, fg, accent, activeBg),
              _headerPill('H2', 2, header, fg, accent, activeBg),
              _headerPill('H3', 3, header, fg, accent, activeBg),
              _vDivider(border),
              _miniBtn(Icons.format_quote, 'Quote',
                  active: _isActive(Attribute.blockQuote),
                  fg: fg, accent: accent, activeBg: activeBg,
                  onTap: () => _toggle(Attribute.blockQuote)),
              _miniBtn(Icons.code, 'Inline code',
                  active: _isActive(Attribute.inlineCode),
                  fg: fg, accent: accent, activeBg: activeBg,
                  onTap: () => _toggle(Attribute.inlineCode)),
              _miniBtn(Icons.link, 'Link',
                  active: _hasLink,
                  fg: fg, accent: accent, activeBg: activeBg,
                  onTap: widget.onOpenLink),
            ],
          ),
        ),
      ),
    );
  }

  Widget _vDivider(Color color) => Container(
        width: 1,
        height: 18,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        color: color,
      );

  Widget _miniBtn(
    IconData icon,
    String tooltip, {
    required bool active,
    required Color fg,
    required Color accent,
    required Color activeBg,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          width: 30,
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: active ? activeBg : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 16, color: active ? accent : fg),
        ),
      ),
    );
  }

  Widget _headerPill(
    String label,
    int level,
    int? current,
    Color fg,
    Color accent,
    Color activeBg,
  ) {
    final active = current == level;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => _applyHeader(active ? null : level),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        margin: const EdgeInsets.symmetric(horizontal: 1),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? activeBg : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: active ? accent : fg,
          ),
        ),
      ),
    );
  }
}
