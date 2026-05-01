import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/models/section_version_model.dart';
import 'package:inkspacex/provider/version_history_provider.dart';

// ── Version label dialog ──
class VersionLabelDialog extends StatefulWidget {
  const VersionLabelDialog({super.key, required this.isDark});
  final bool isDark;

  @override
  State<VersionLabelDialog> createState() => _VersionLabelDialogState();
}

class _VersionLabelDialogState extends State<VersionLabelDialog> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final fg = isDark ? Colors.white : const Color(0xFF1A1A1F);
    final mutedFg = fg.withValues(alpha: 0.55);
    final bg = isDark ? const Color(0xFF1F2126) : Colors.white;
    final fieldBg = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.04);
    return Dialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Save version',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Optional label, e.g. "draft 2" or "before rewrite".',
                style: GoogleFonts.inter(fontSize: 12, color: mutedFg),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _ctrl,
                focusNode: _focus,
                style: GoogleFonts.inter(fontSize: 13, color: fg),
                decoration: InputDecoration(
                  hintText: 'Label (optional)',
                  hintStyle: GoogleFonts.inter(fontSize: 13, color: mutedFg),
                  filled: true,
                  fillColor: fieldBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (v) => Navigator.pop(context, v),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Cancel',
                        style:
                            GoogleFonts.inter(fontSize: 13, color: mutedFg)),
                  ),
                  const SizedBox(width: 4),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A6CF7),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                    child: Text('Save',
                        style: GoogleFonts.inter(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Version history sheet ──
class VersionHistorySheet extends StatelessWidget {
  const VersionHistorySheet({
    super.key,
    required this.scrollController,
    required this.isDark,
    required this.onSaveCurrent,
    required this.onRestore,
  });

  final ScrollController scrollController;
  final bool isDark;
  final VoidCallback onSaveCurrent;
  final void Function(SectionVersion) onRestore;

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xFF0C0C0C) : Colors.white;
    final fg = isDark ? Colors.white : const Color(0xFF1A1A1F);
    final mutedFg = fg.withValues(alpha: 0.55);
    final divider = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final vh = context.watch<VersionHistoryProvider>();
    final items = [...vh.versions]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

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
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
            child: Row(
              children: [
                Icon(CupertinoIcons.clock, size: 18, color: fg),
                const SizedBox(width: 10),
                Text(
                  'Version history',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: onSaveCurrent,
                  icon: Icon(CupertinoIcons.bookmark,
                      size: 14, color: fg.withValues(alpha: 0.85)),
                  label: Text('Save current',
                      style: GoogleFonts.inter(fontSize: 12, color: fg)),
                ),
              ],
            ),
          ),
          Divider(color: divider, height: 1),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'No versions yet. Snapshots are auto-saved when you '
                        'pause typing for ~30 seconds, or hit "Save current".',
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
                    itemCount: items.length,
                    separatorBuilder: (_, _) =>
                        Divider(color: divider, height: 1),
                    itemBuilder: (_, i) {
                      final v = items[i];
                      return _row(context, v, fg, mutedFg);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, SectionVersion v, Color fg, Color mutedFg) {
    final stamp = _format(v.createdAt);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Icon(
            v.manual ? CupertinoIcons.bookmark_fill : CupertinoIcons.clock,
            size: 14,
            color: v.manual ? const Color(0xFFFFC857) : mutedFg,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  v.label.isNotEmpty ? v.label : stamp,
                  style: GoogleFonts.inter(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${v.label.isNotEmpty ? '$stamp · ' : ''}${v.wordCount} word${v.wordCount == 1 ? '' : 's'}',
                  style: GoogleFonts.inter(fontSize: 11.5, color: mutedFg),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => onRestore(v),
            child: Text('Restore',
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: 'Delete',
            iconSize: 14,
            color: mutedFg,
            icon: const Icon(CupertinoIcons.trash),
            onPressed: () =>
                context.read<VersionHistoryProvider>().deleteVersion(v.id),
          ),
        ],
      ),
    );
  }

  String _format(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final today = DateTime.now();
    final isToday = t.year == today.year &&
        t.month == today.month &&
        t.day == today.day;
    final time = '${two(t.hour)}:${two(t.minute)}';
    if (isToday) return 'Today, $time';
    return '${t.year}-${two(t.month)}-${two(t.day)} $time';
  }
}
