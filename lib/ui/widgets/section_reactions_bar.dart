import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';

/// Inline pill row of emoji reactions for a chapter.
///
/// Renders the existing aggregate as `❤ 12 🔥 4 +`, where:
/// * each emoji-with-count pill toggles the viewer's reaction
///   (highlighted background when `you=true`),
/// * the trailing `+` opens a horizontal picker of the eight Phase-1
///   emojis the backend allows.
///
/// State is optimistic: tap → UI flips immediately, then the server
/// response replaces the aggregate. On failure we revert silently
/// (a snackbar would interrupt the reading flow more than it helps).
class SectionReactionsBar extends StatefulWidget {
  final String feedItemId;
  final FeedItemSection section;
  final bool isDark;
  const SectionReactionsBar({
    super.key,
    required this.feedItemId,
    required this.section,
    required this.isDark,
  });

  @override
  State<SectionReactionsBar> createState() => _SectionReactionsBarState();
}

class _SectionReactionsBarState extends State<SectionReactionsBar> {
  // The eight Phase-1 emojis. Mirrors the server-side allowlist in
  // backend/app/routers/section_reactions.py — keep them in sync if
  // the picker grows.
  static const List<String> _pickerEmojis = [
    '❤️', '🔥', '😂', '😢', '😮', '👏', '🤔', '⭐',
  ];

  late List<SectionReactionAggregate> _reactions;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reactions = List.of(widget.section.reactions);
  }

  @override
  void didUpdateWidget(covariant SectionReactionsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The reader rebuilds this widget when the user navigates between
    // chapters; pick up the new section's reactions.
    if (oldWidget.section.id != widget.section.id) {
      _reactions = List.of(widget.section.reactions);
    }
  }

  Future<void> _toggle(String emoji) async {
    if (_busy) return;
    final existing = _reactions.firstWhere(
      (r) => r.emoji == emoji,
      orElse: () =>
          const SectionReactionAggregate(emoji: '', count: 0, you: false),
    );
    final wasYours = existing.emoji.isNotEmpty && existing.you;
    // Optimistic flip.
    final snapshot = List<SectionReactionAggregate>.from(_reactions);
    setState(() {
      _busy = true;
      _reactions = _applyOptimistic(emoji, !wasYours);
    });
    try {
      final api = context.read<AuthProvider>().dataService;
      final updated = wasYours
          ? await api.removeSectionReaction(
              feedItemId: widget.feedItemId,
              sectionId: widget.section.id,
              emoji: emoji,
            )
          : await api.addSectionReaction(
              feedItemId: widget.feedItemId,
              sectionId: widget.section.id,
              emoji: emoji,
            );
      if (!mounted) return;
      setState(() => _reactions = updated);
      // Push the new aggregate up to the feed cache so the chapter
      // list / overview reflects it without a refetch.
      context.read<FeedProvider?>()?.updateSectionReactions(
            widget.feedItemId,
            widget.section.id,
            updated,
          );
    } catch (_) {
      if (!mounted) return;
      setState(() => _reactions = snapshot);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<SectionReactionAggregate> _applyOptimistic(
    String emoji,
    bool addNotRemove,
  ) {
    final out = <SectionReactionAggregate>[];
    var matched = false;
    for (final r in _reactions) {
      if (r.emoji == emoji) {
        matched = true;
        final next = r.copyWith(
          count: addNotRemove ? r.count + 1 : (r.count - 1).clamp(0, 1 << 30),
          you: addNotRemove,
        );
        if (next.count > 0) out.add(next);
      } else {
        out.add(r);
      }
    }
    if (!matched && addNotRemove) {
      out.add(SectionReactionAggregate(emoji: emoji, count: 1, you: true));
    }
    out.sort((a, b) => b.count.compareTo(a.count));
    return out;
  }

  void _openPicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: widget.isDark
          ? const Color(0xFF1A1A1A)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: (widget.isDark ? Colors.white : Colors.black)
                      .withOpacity(0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final emoji in _pickerEmojis)
                    InkWell(
                      borderRadius: BorderRadius.circular(28),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        _toggle(emoji);
                      },
                      child: Container(
                        width: 56,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: (widget.isDark ? Colors.white : Colors.black)
                              .withOpacity(0.06),
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: Text(emoji, style: const TextStyle(fontSize: 28)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.isDark ? Colors.white : Colors.black;
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        children: [
          for (final r in _reactions)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _ReactionPill(
                emoji: r.emoji,
                count: r.count,
                active: r.you,
                fg: fg,
                onTap: _busy ? null : () => _toggle(r.emoji),
              ),
            ),
          _AddPill(fg: fg, onTap: _busy ? null : _openPicker),
        ],
      ),
    );
  }
}

class _ReactionPill extends StatelessWidget {
  final String emoji;
  final int count;
  final bool active;
  final Color fg;
  final VoidCallback? onTap;
  const _ReactionPill({
    required this.emoji,
    required this.count,
    required this.active,
    required this.fg,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = active ? fg.withOpacity(0.18) : fg.withOpacity(0.06);
    final border = active ? fg.withOpacity(0.5) : fg.withOpacity(0.12);
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: border, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddPill extends StatelessWidget {
  final Color fg;
  final VoidCallback? onTap;
  const _AddPill({required this.fg, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        height: 36,
        width: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fg.withOpacity(0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: fg.withOpacity(0.12), width: 1),
        ),
        child: Icon(Icons.add_reaction_outlined, size: 18, color: fg),
      ),
    );
  }
}
