import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:inkspacex/services/toolbar_usage.dart';

/// A compact format bar that appears at the top of the editor area
/// whenever there is a non-collapsed text selection.
///
/// Word's "mini toolbar" pattern: instead of forcing the user to fish
/// through the main ribbon for the common format toggles, the most-used
/// actions float into reach the moment text is highlighted.
///
/// Layout adapts to the user — `B / I / U` are pinned to the left because
/// they are universal, and the remaining slots are sorted by lifetime
/// click count from `ToolbarUsage`. Order recomputes only when the
/// selection changes (i.e., on each show), so the bar never reshuffles
/// while the user is mid-click.
class FloatingFormatBar extends StatefulWidget {
  const FloatingFormatBar({
    super.key,
    required this.controller,
    required this.isDark,
    required this.onOpenLink,
    required this.onAI,
  });

  final QuillController controller;
  final bool isDark;
  final VoidCallback onOpenLink;
  final VoidCallback onAI;

  @override
  State<FloatingFormatBar> createState() => _FloatingFormatBarState();
}

// ── Action ids (also used as ToolbarUsage keys) ──
const _idBold = 'fmt.bold';
const _idItalic = 'fmt.italic';
const _idUnderline = 'fmt.underline';
const _idStrike = 'fmt.strike';
const _idH1 = 'fmt.h1';
const _idH2 = 'fmt.h2';
const _idH3 = 'fmt.h3';
const _idQuote = 'fmt.quote';
const _idCode = 'fmt.code';
const _idLink = 'fmt.link';
const _idAi = 'fmt.ai';

class _FloatingFormatBarState extends State<FloatingFormatBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  bool _visible = false;
  // Action ids ordered for the current show. Frozen until selection
  // changes so the bar doesn't reshuffle under the user's cursor.
  List<String> _adaptiveOrder = const [];

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
    ToolbarUsage.instance.load();
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
    setState(() {
      _visible = shouldShow;
      if (shouldShow) _adaptiveOrder = _computeOrder();
    });
    if (shouldShow) {
      _anim.forward();
    } else {
      _anim.reverse();
    }
  }

  // Recompute the per-show order: pinned core (B/I/U) first, then the
  // remaining candidates sorted by lifetime click count.
  List<String> _computeOrder() {
    const pinned = [_idBold, _idItalic, _idUnderline];
    const adaptive = [
      _idStrike,
      _idH1,
      _idH2,
      _idH3,
      _idQuote,
      _idCode,
      _idLink,
      _idAi,
    ];
    return [
      ...pinned,
      ...ToolbarUsage.instance.sortedByUsage(adaptive),
    ];
  }

  bool _isActive(Attribute attr) =>
      widget.controller.getSelectionStyle().attributes.containsKey(attr.key);

  void _toggle(Attribute attr, String id) {
    ToolbarUsage.instance.increment(id);
    final active = _isActive(attr);
    widget.controller
        .formatSelection(active ? Attribute.clone(attr, null) : attr);
    setState(() {});
  }

  void _applyHeader(int? level, String id) {
    ToolbarUsage.instance.increment(id);
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

  bool get _hasLink => widget.controller
      .getSelectionStyle()
      .attributes
      .containsKey(Attribute.link.key);

  // Visual cluster for an action — used to insert dividers when the
  // group changes between adjacent items.
  String _groupOf(String id) {
    switch (id) {
      case _idBold:
      case _idItalic:
      case _idUnderline:
      case _idStrike:
        return 'mark';
      case _idH1:
      case _idH2:
      case _idH3:
        return 'header';
      case _idQuote:
      case _idCode:
      case _idLink:
        return 'block';
      case _idAi:
        return 'ai';
    }
    return 'misc';
  }

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
    final order = _adaptiveOrder.isEmpty ? _computeOrder() : _adaptiveOrder;

    final children = <Widget>[];
    String? prevGroup;
    for (final id in order) {
      final group = _groupOf(id);
      if (prevGroup != null && group != prevGroup) {
        children.add(_vDivider(border));
      }
      prevGroup = group;
      children.add(_render(
        id: id,
        fg: fg,
        accent: accent,
        activeBg: activeBg,
        header: header,
      ));
    }

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
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }

  Widget _render({
    required String id,
    required Color fg,
    required Color accent,
    required Color activeBg,
    required int? header,
  }) {
    switch (id) {
      case _idBold:
        return _miniBtn(Icons.format_bold, 'Bold',
            active: _isActive(Attribute.bold),
            fg: fg, accent: accent, activeBg: activeBg,
            onTap: () => _toggle(Attribute.bold, id));
      case _idItalic:
        return _miniBtn(Icons.format_italic, 'Italic',
            active: _isActive(Attribute.italic),
            fg: fg, accent: accent, activeBg: activeBg,
            onTap: () => _toggle(Attribute.italic, id));
      case _idUnderline:
        return _miniBtn(Icons.format_underline, 'Underline',
            active: _isActive(Attribute.underline),
            fg: fg, accent: accent, activeBg: activeBg,
            onTap: () => _toggle(Attribute.underline, id));
      case _idStrike:
        return _miniBtn(Icons.format_strikethrough, 'Strikethrough',
            active: _isActive(Attribute.strikeThrough),
            fg: fg, accent: accent, activeBg: activeBg,
            onTap: () => _toggle(Attribute.strikeThrough, id));
      case _idH1:
        return _headerPill('H1', 1, header, fg, accent, activeBg, id);
      case _idH2:
        return _headerPill('H2', 2, header, fg, accent, activeBg, id);
      case _idH3:
        return _headerPill('H3', 3, header, fg, accent, activeBg, id);
      case _idQuote:
        return _miniBtn(Icons.format_quote, 'Quote',
            active: _isActive(Attribute.blockQuote),
            fg: fg, accent: accent, activeBg: activeBg,
            onTap: () => _toggle(Attribute.blockQuote, id));
      case _idCode:
        return _miniBtn(Icons.code, 'Inline code',
            active: _isActive(Attribute.inlineCode),
            fg: fg, accent: accent, activeBg: activeBg,
            onTap: () => _toggle(Attribute.inlineCode, id));
      case _idLink:
        return _miniBtn(Icons.link, 'Link',
            active: _hasLink,
            fg: fg, accent: accent, activeBg: activeBg, onTap: () {
          ToolbarUsage.instance.increment(id);
          widget.onOpenLink();
        });
      case _idAi:
        return _miniBtn(CupertinoIcons.wand_stars, 'AI assist',
            active: false,
            fg: accent, accent: accent, activeBg: activeBg, onTap: () {
          ToolbarUsage.instance.increment(id);
          widget.onAI();
        });
    }
    return const SizedBox.shrink();
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
    String id,
  ) {
    final active = current == level;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => _applyHeader(active ? null : level, id),
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
