import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Modal picker over the full Google Fonts catalog (~1500 fonts).
///
/// Each row renders the font name in its own font as a live preview;
/// `ListView.builder` virtualises so only the visible rows actually trigger
/// a font load. The user's curated/popular list is pinned to the top and
/// remains visible while searching.
Future<String?> showFontPicker(
  BuildContext context, {
  required String current,
  required List<String> popular,
  required bool isDark,
}) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (ctx) => _FontPickerDialog(
      current: current,
      popular: popular,
      isDark: isDark,
    ),
  );
}

class _FontPickerDialog extends StatefulWidget {
  const _FontPickerDialog({
    required this.current,
    required this.popular,
    required this.isDark,
  });

  final String current;
  final List<String> popular;
  final bool isDark;

  @override
  State<_FontPickerDialog> createState() => _FontPickerDialogState();
}

class _FontPickerDialogState extends State<_FontPickerDialog> {
  static List<String>? _cachedAll;

  final _query = TextEditingController();
  final _focus = FocusNode();
  late List<String> _all;
  late List<String> _filtered;

  @override
  void initState() {
    super.initState();
    // Cache the full catalog the first time the picker opens — asMap()
    // builds a 1500-entry map and the keys list has thousands of strings,
    // so we don't want to redo it on every reopen.
    _all = _cachedAll ??= GoogleFonts.asMap().keys.toList()..sort();
    _filtered = _all;
    _query.addListener(_refilter);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _refilter() {
    final q = _query.text.toLowerCase().trim();
    setState(() {
      _filtered = q.isEmpty
          ? _all
          : _all.where((n) => n.toLowerCase().contains(q)).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final bg = isDark ? const Color(0xFF1B1D22) : Colors.white;
    final fg = isDark ? Colors.white : const Color(0xFF1A1A1F);
    final muted = fg.withValues(alpha: 0.55);
    final accent =
        isDark ? const Color(0xFF93B4F5) : const Color(0xFF4A6CF7);
    final activeBg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFFEFF3FE);
    final border = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.06);
    final hoverBg = isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.black.withValues(alpha: 0.025);

    final query = _query.text.trim();
    final showPopular = query.isEmpty;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
      child: Container(
        width: 460,
        constraints: const BoxConstraints(maxHeight: 560),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.55 : 0.18),
              blurRadius: 40,
              spreadRadius: -8,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Search ──
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: border)),
              ),
              child: Row(
                children: [
                  Icon(CupertinoIcons.search, size: 16, color: muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _query,
                      focusNode: _focus,
                      autofocus: true,
                      cursorColor: accent,
                      cursorWidth: 1.4,
                      style: TextStyle(fontSize: 14, color: fg),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: 'Search ${_all.length} Google Fonts…',
                        hintStyle: TextStyle(fontSize: 14, color: muted),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── List ──
            Flexible(
              child: _filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        'No matching fonts',
                        style: TextStyle(fontSize: 13, color: muted),
                      ),
                    )
                  : CustomScrollView(
                      slivers: [
                        if (showPopular) ...[
                          SliverToBoxAdapter(
                            child: _sectionLabel('Popular', muted),
                          ),
                          SliverList.builder(
                            itemCount: widget.popular.length,
                            itemBuilder: (_, i) => _row(
                              widget.popular[i],
                              fg,
                              accent,
                              activeBg,
                              hoverBg,
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: _sectionLabel('All fonts', muted),
                          ),
                        ],
                        SliverList.builder(
                          itemCount: _filtered.length,
                          itemBuilder: (_, i) => _row(
                            _filtered[i],
                            fg,
                            accent,
                            activeBg,
                            hoverBg,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text, Color muted) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: muted,
            letterSpacing: 0.8,
          ),
        ),
      );

  Widget _row(
    String name,
    Color fg,
    Color accent,
    Color activeBg,
    Color hoverBg,
  ) {
    final selected = name == widget.current;
    return _HoverRow(
      hoverBg: hoverBg,
      onTap: () => Navigator.of(context).pop(name),
      child: Container(
        color: selected ? activeBg : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: _safeGoogleFont(name).copyWith(
                  fontSize: 16,
                  color: selected ? accent : fg,
                ),
              ),
            ),
            if (selected)
              Icon(CupertinoIcons.check_mark, size: 14, color: accent),
          ],
        ),
      ),
    );
  }
}

// Some Google Fonts variants (older shipped fonts, regional families)
// occasionally throw if assets are missing — fall back silently so a single
// bad font doesn't break the entire list.
TextStyle _safeGoogleFont(String name) {
  try {
    return GoogleFonts.getFont(name);
  } catch (_) {
    return TextStyle(fontFamily: name);
  }
}

class _HoverRow extends StatefulWidget {
  const _HoverRow({
    required this.child,
    required this.onTap,
    required this.hoverBg,
  });

  final Widget child;
  final VoidCallback onTap;
  final Color hoverBg;

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: _hover ? widget.hoverBg : Colors.transparent,
          child: widget.child,
        ),
      ),
    );
  }
}
