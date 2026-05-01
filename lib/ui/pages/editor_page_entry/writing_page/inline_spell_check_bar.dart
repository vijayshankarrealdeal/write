import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/spell_check_provider.dart';
import 'package:inkspacex/services/spell_check_service.dart' as spellsvc;
import 'package:inkspacex/ui/widgets/app_spinner.dart';

/// Compact correction bar that appears at the top of the editor area when
/// the caret is inside a misspelled span. Mirrors the FloatingFormatBar
/// pattern: instead of forcing the user to open the issues bottom-sheet
/// for a one-word fix, the top suggestions float into reach as soon as
/// they tap the underlined word.
///
/// Hides itself when the selection is non-collapsed (the FloatingFormatBar
/// owns that case) or when the caret leaves every misspelling range.
class InlineSpellCheckBar extends StatefulWidget {
  const InlineSpellCheckBar({
    super.key,
    required this.controller,
    required this.isDark,
    required this.onReplace,
    required this.onAddToDictionary,
    required this.onIgnore,
  });

  final QuillController controller;
  final bool isDark;
  final void Function(spellsvc.Misspelling, String) onReplace;
  final void Function(spellsvc.Misspelling) onAddToDictionary;
  final void Function(spellsvc.Misspelling) onIgnore;

  @override
  State<InlineSpellCheckBar> createState() => _InlineSpellCheckBarState();
}

class _InlineSpellCheckBarState extends State<InlineSpellCheckBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  bool _visible = false;

  spellsvc.Misspelling? _active;
  List<String>? _suggestions;
  bool _loading = false;
  // Tracks the in-flight suggest request so a stale response can't overwrite
  // a newer word's suggestions if the user hops between misspellings fast.
  String? _pendingFor;

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
    // Re-evaluate when the issue list itself changes (e.g., scan finishes
    // while the caret is already parked inside a still-misspelled word).
    final sp = context.read<SpellCheckProvider>();
    sp.addListener(_onChange);
    _evaluate();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    if (mounted) {
      // Provider lookup during dispose is unsafe via context.read on a
      // disposed element, so guard with mounted.
      try {
        context.read<SpellCheckProvider>().removeListener(_onChange);
      } catch (_) {}
    }
    _anim.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    _evaluate();
  }

  void _evaluate() {
    final sel = widget.controller.selection;
    // Only surface for a plain caret. A real text selection means the user
    // is formatting, which the FloatingFormatBar handles.
    if (!sel.isValid || !sel.isCollapsed) {
      _hide();
      return;
    }
    final sp = context.read<SpellCheckProvider>();
    if (!sp.enabled) {
      _hide();
      return;
    }
    final hit = sp.issueAt(sel.baseOffset);
    if (hit == null) {
      _hide();
      return;
    }
    final isSame = _active != null &&
        _active!.start == hit.start &&
        _active!.length == hit.length &&
        _active!.word == hit.word;
    if (isSame && _visible) return;

    setState(() {
      _active = hit;
      _visible = true;
      if (!isSame) {
        _suggestions = null;
        _loading = false;
      }
    });
    _anim.forward();
    if (!isSame) _loadSuggestions(hit);
  }

  void _hide() {
    if (!_visible) return;
    setState(() {
      _visible = false;
      _active = null;
      _suggestions = null;
      _loading = false;
      _pendingFor = null;
    });
    _anim.reverse();
  }

  Future<void> _loadSuggestions(spellsvc.Misspelling m) async {
    setState(() => _loading = true);
    _pendingFor = m.word;
    final sp = context.read<SpellCheckProvider>();
    final result = await sp.suggest(m.word, max: 4);
    if (!mounted) return;
    // Stale response — caret moved to a different word while we waited.
    if (_pendingFor != m.word || _active?.word != m.word) return;
    setState(() {
      _suggestions = result;
      _loading = false;
    });
  }

  void _replace(String s) {
    final m = _active;
    if (m == null) return;
    widget.onReplace(m, s);
    _hide();
  }

  void _add() {
    final m = _active;
    if (m == null) return;
    widget.onAddToDictionary(m);
    _hide();
  }

  void _ignore() {
    final m = _active;
    if (m == null) return;
    widget.onIgnore(m);
    _hide();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible && _anim.isDismissed) return const SizedBox.shrink();

    final isDark = widget.isDark;
    // Surface sits a notch above the editor's paper (which goes as dark as
    // 0xFF131315) so the bar reads as a floating layer without taking on
    // the cool slate tint the previous palette had. Light mode keeps a
    // warm off-white that pairs with the coral accent.
    final bg = isDark ? const Color(0xFF1C1C1F) : const Color(0xFFFBFAF7);
    final fg = isDark ? Colors.white : const Color(0xFF1A1A1F);
    final mutedFg = fg.withValues(alpha: 0.55);
    final accent = const Color(0xFFE26A4A);
    final border = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    // Chip fill borrows a whisper of the accent so the suggestions feel
    // related to the underline they're correcting instead of stamped from
    // a generic component library.
    final chipBg = isDark
        ? const Color(0xFFE26A4A).withValues(alpha: 0.10)
        : const Color(0xFFE26A4A).withValues(alpha: 0.07);
    final chipBorder = isDark
        ? const Color(0xFFE26A4A).withValues(alpha: 0.18)
        : const Color(0xFFE26A4A).withValues(alpha: 0.16);
    final divider = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    final m = _active;
    final suggestions = _suggestions ?? const <String>[];

    return SlideTransition(
      position: _slide,
      child: FadeTransition(
        opacity: _fade,
        child: Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          constraints: const BoxConstraints(maxWidth: 520),
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
              Icon(CupertinoIcons.exclamationmark_circle,
                  size: 14, color: accent),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  m?.word ?? '',
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: fg,
                    decoration: TextDecoration.underline,
                    decorationStyle: TextDecorationStyle.wavy,
                    decorationColor: accent.withValues(alpha: 0.85),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(width: 1, height: 18, color: divider),
              const SizedBox(width: 8),
              if (_loading)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: AppSpinner(size: 12, color: mutedFg),
                )
              else if (suggestions.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'No suggestions',
                    style: GoogleFonts.inter(fontSize: 12, color: mutedFg),
                  ),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final s in suggestions)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: _chip(
                              label: s,
                              fg: fg,
                              bg: chipBg,
                              border: chipBorder,
                              onTap: () => _replace(s),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              Container(width: 1, height: 18, color: divider),
              _iconButton(
                icon: CupertinoIcons.add,
                tooltip: 'Add to dictionary',
                fg: fg,
                onTap: _add,
              ),
              _iconButton(
                icon: CupertinoIcons.eye_slash,
                tooltip: 'Ignore once',
                fg: mutedFg,
                onTap: _ignore,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip({
    required String label,
    required Color fg,
    required Color bg,
    required Color border,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: border),
          ),
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required Color fg,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      waitDuration: const Duration(milliseconds: 250),
      child: InkResponse(
        onTap: onTap,
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 14, color: fg),
        ),
      ),
    );
  }
}
