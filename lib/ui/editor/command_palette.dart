import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class PaletteCommand {
  PaletteCommand({
    required this.id,
    required this.label,
    required this.group,
    required this.icon,
    required this.run,
    this.shortcut,
    this.keywords = const [],
  });

  final String id;
  final String label;
  final String group;
  final IconData icon;
  final VoidCallback run;
  final String? shortcut;
  final List<String> keywords;
}

/// Modal command palette (Cmd/Ctrl+K). Searchable list of editor
/// commands and section jumps. Closes on Esc or Enter.
Future<void> showCommandPalette({
  required BuildContext context,
  required List<PaletteCommand> commands,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Command palette',
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (ctx, _, _) => _PaletteSheet(commands: commands),
    transitionBuilder: (ctx, anim, _, child) {
      final curve = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curve,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curve),
          child: child,
        ),
      );
    },
  );
}

class _PaletteSheet extends StatefulWidget {
  const _PaletteSheet({required this.commands});

  final List<PaletteCommand> commands;

  @override
  State<_PaletteSheet> createState() => _PaletteSheetState();
}

class _PaletteSheetState extends State<_PaletteSheet> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  int _highlight = 0;
  late List<PaletteCommand> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = widget.commands;
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
          ? widget.commands
          : widget.commands
              .where((c) =>
                  c.label.toLowerCase().contains(q) ||
                  c.group.toLowerCase().contains(q) ||
                  c.keywords.any((k) => k.toLowerCase().contains(q)))
              .toList();
      _highlight = 0;
    });
  }

  void _run(PaletteCommand cmd) {
    Navigator.of(context).pop();
    cmd.run();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_filtered.isEmpty) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight = (_highlight + 1) % _filtered.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() =>
          _highlight = (_highlight - 1 + _filtered.length) % _filtered.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _run(_filtered[_highlight.clamp(0, _filtered.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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

    final width = MediaQuery.sizeOf(context).width.clamp(0.0, 560.0);

    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 80),
        child: Align(
          alignment: Alignment.topCenter,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: width,
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                        alpha: isDark ? 0.55 : 0.18),
                    blurRadius: 40,
                    spreadRadius: -8,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Search input ──
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
                    decoration: BoxDecoration(
                      border:
                          Border(bottom: BorderSide(color: border)),
                    ),
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.search,
                            size: 16, color: muted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Focus(
                            onKeyEvent: _onKey,
                            child: TextField(
                              controller: _query,
                              focusNode: _focus,
                              autofocus: true,
                              cursorColor: accent,
                              cursorWidth: 1.4,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                color: fg,
                              ),
                              decoration: InputDecoration(
                                isCollapsed: true,
                                border: InputBorder.none,
                                hintText:
                                    'Type a command or search…',
                                hintStyle: GoogleFonts.inter(
                                  fontSize: 14,
                                  color: muted,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: activeBg,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: border),
                          ),
                          child: Text(
                            'esc',
                            style: GoogleFonts.jetBrainsMono(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── Results list ──
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 380),
                    child: _filtered.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(28),
                            child: Text(
                              'No matching commands',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color: muted,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          )
                        : ListView.builder(
                            padding:
                                const EdgeInsets.symmetric(vertical: 6),
                            shrinkWrap: true,
                            itemCount: _filtered.length,
                            itemBuilder: (_, i) {
                              final cmd = _filtered[i];
                              final active = i == _highlight;
                              final showGroupHeader = i == 0 ||
                                  _filtered[i - 1].group != cmd.group;
                              return Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  if (showGroupHeader)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          16, 8, 16, 4),
                                      child: Text(
                                        cmd.group.toUpperCase(),
                                        style: GoogleFonts.inter(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: muted,
                                          letterSpacing: 0.8,
                                        ),
                                      ),
                                    ),
                                  InkWell(
                                    onTap: () => _run(cmd),
                                    onHover: (h) {
                                      if (h && _highlight != i) {
                                        setState(() => _highlight = i);
                                      }
                                    },
                                    child: Container(
                                      color: active
                                          ? activeBg
                                          : Colors.transparent,
                                      padding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 9),
                                      child: Row(
                                        children: [
                                          Icon(
                                            cmd.icon,
                                            size: 16,
                                            color: active
                                                ? accent
                                                : fg.withValues(
                                                    alpha: 0.7),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              cmd.label,
                                              style: GoogleFonts.inter(
                                                fontSize: 13,
                                                fontWeight:
                                                    FontWeight.w500,
                                                color: fg,
                                              ),
                                            ),
                                          ),
                                          if (cmd.shortcut != null)
                                            Container(
                                              padding: const EdgeInsets
                                                  .symmetric(
                                                  horizontal: 6,
                                                  vertical: 2),
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                        4),
                                                border: Border.all(
                                                    color: border),
                                              ),
                                              child: Text(
                                                cmd.shortcut!,
                                                style: GoogleFonts
                                                    .jetBrainsMono(
                                                  fontSize: 10,
                                                  fontWeight:
                                                      FontWeight.w600,
                                                  color: muted,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
