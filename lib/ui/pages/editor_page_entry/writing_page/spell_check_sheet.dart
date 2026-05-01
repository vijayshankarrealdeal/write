import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/provider/spell_check_provider.dart';
import 'package:inkspacex/services/spell_check_service.dart' as spellsvc;
import 'package:inkspacex/ui/widgets/app_spinner.dart';

// ── Spell check sheet ──
//
// Lists misspellings in document order. Tapping an entry shows its
// suggestions inline; selecting a suggestion replaces the word in the
// editor; "Ignore" adds it to the user's personal dictionary.
class SpellCheckSheet extends StatelessWidget {
  const SpellCheckSheet({
    super.key,
    required this.scrollController,
    required this.isDark,
    required this.onJump,
    required this.onReplace,
    required this.onIgnore,
  });

  final ScrollController scrollController;
  final bool isDark;
  final void Function(spellsvc.Misspelling) onJump;
  final void Function(spellsvc.Misspelling, String) onReplace;
  final void Function(spellsvc.Misspelling) onIgnore;

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xFF0C0C0C) : Colors.white;
    final fg = isDark ? Colors.white : const Color(0xFF1A1A1F);
    final mutedFg = fg.withValues(alpha: 0.55);
    final divider = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final sp = context.watch<SpellCheckProvider>();
    final issues = sp.issues;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
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
                Icon(CupertinoIcons.checkmark_seal, size: 18, color: fg),
                const SizedBox(width: 10),
                Text(
                  'Spelling',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
                const Spacer(),
                if (sp.scanning)
                  AppSpinner(size: 14, color: mutedFg)
                else
                  Text(
                    issues.isEmpty
                        ? 'No issues'
                        : '${issues.length} issue${issues.length == 1 ? '' : 's'}',
                    style: GoogleFonts.inter(fontSize: 12, color: mutedFg),
                  ),
              ],
            ),
          ),
          Divider(color: divider, height: 1),
          Expanded(
            child: issues.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        sp.enabled
                            ? 'Looking good — no spelling issues found.'
                            : 'Spell check is turned off. Enable it from Writer Settings.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 12.5,
                          color: mutedFg,
                          height: 1.5,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    controller: scrollController,
                    itemCount: issues.length,
                    separatorBuilder: (_, _) =>
                        Divider(color: divider, height: 1),
                    itemBuilder: (_, i) {
                      final m = issues[i];
                      return _IssueRow(
                        misspelling: m,
                        fg: fg,
                        mutedFg: mutedFg,
                        onJump: () => onJump(m),
                        onReplace: (s) {
                          onReplace(m, s);
                        },
                        onIgnore: () => onIgnore(m),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _IssueRow extends StatefulWidget {
  const _IssueRow({
    required this.misspelling,
    required this.fg,
    required this.mutedFg,
    required this.onJump,
    required this.onReplace,
    required this.onIgnore,
  });

  final spellsvc.Misspelling misspelling;
  final Color fg;
  final Color mutedFg;
  final VoidCallback onJump;
  final void Function(String) onReplace;
  final VoidCallback onIgnore;

  @override
  State<_IssueRow> createState() => _IssueRowState();
}

class _IssueRowState extends State<_IssueRow> {
  bool _expanded = false;
  List<String>? _suggestions;
  bool _loadingSuggestions = false;

  Future<void> _toggle() async {
    final willExpand = !_expanded;
    setState(() => _expanded = willExpand);
    widget.onJump();
    if (willExpand && _suggestions == null && !_loadingSuggestions) {
      setState(() => _loadingSuggestions = true);
      final sp = context.read<SpellCheckProvider>();
      final result = await sp.suggest(widget.misspelling.word);
      if (!mounted) return;
      setState(() {
        _suggestions = result;
        _loadingSuggestions = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.misspelling;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(6),
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? CupertinoIcons.chevron_down
                      : CupertinoIcons.chevron_right,
                  size: 12,
                  color: widget.mutedFg,
                ),
                const SizedBox(width: 10),
                Text(
                  m.word,
                  style: GoogleFonts.inter(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: widget.fg,
                    decoration: TextDecoration.underline,
                    decorationStyle: TextDecorationStyle.wavy,
                    decorationColor:
                        const Color(0xFFE26A4A).withValues(alpha: 0.85),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: widget.onIgnore,
                  child: Text(
                    'Ignore',
                    style: GoogleFonts.inter(
                        fontSize: 12, color: widget.mutedFg),
                  ),
                ),
              ],
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 6),
            if (_loadingSuggestions)
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 4),
                child: Row(
                  children: [
                    AppSpinner(size: 12, color: widget.mutedFg),
                    const SizedBox(width: 8),
                    Text(
                      'Loading suggestions…',
                      style: GoogleFonts.inter(
                          fontSize: 12, color: widget.mutedFg),
                    ),
                  ],
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.only(left: 22),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: (_suggestions ?? const [])
                      .map((s) => ActionChip(
                            label: Text(
                              s,
                              style: GoogleFonts.inter(fontSize: 12),
                            ),
                            onPressed: () => widget.onReplace(s),
                          ))
                      .toList(),
                ),
              ),
              if ((_suggestions ?? const []).isEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 22, top: 4),
                  child: Text(
                    'No suggestions.',
                    style: GoogleFonts.inter(
                        fontSize: 12, color: widget.mutedFg),
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}
