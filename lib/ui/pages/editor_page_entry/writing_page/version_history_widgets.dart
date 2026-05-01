import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
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
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Dialog(
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

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Container(
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
        ),
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
            child: Text('Preview',
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

// ── Version preview page ──
/// Read-only render of a snapshot's content so the user can scan it
/// before confirming a restore. Returns `true` from the route if the
/// user taps "Restore this version".
class VersionPreviewPage extends StatefulWidget {
  const VersionPreviewPage({
    super.key,
    required this.version,
    required this.isDark,
  });

  final SectionVersion version;
  final bool isDark;

  @override
  State<VersionPreviewPage> createState() => _VersionPreviewPageState();
}

class _VersionPreviewPageState extends State<VersionPreviewPage> {
  QuillController? _ctrl;
  bool _decodeFailed = false;

  @override
  void initState() {
    super.initState();
    try {
      final list = jsonDecode(widget.version.contentJson);
      if (list is List) {
        _ctrl = QuillController(
          document: Document.fromJson(list),
          selection: const TextSelection.collapsed(offset: 0),
          readOnly: true,
        );
      } else {
        _decodeFailed = true;
      }
    } catch (_) {
      _decodeFailed = true;
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final fg = isDark ? Colors.white : const Color(0xFF1A1A1F);
    final mutedFg = fg.withValues(alpha: 0.55);
    final bg = isDark ? const Color(0xFF0C0C0C) : Colors.white;
    final divider = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final v = widget.version;
    final stamp = _formatStamp(v.createdAt);
    final wc = '${v.wordCount} word${v.wordCount == 1 ? '' : 's'}';

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context, false),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(CupertinoIcons.xmark, color: fg, size: 20),
          onPressed: () => Navigator.pop(context, false),
        ),
        title: Text(
          'Preview version',
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: divider, height: 1),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
            child: Row(
              children: [
                Icon(
                  v.manual ? CupertinoIcons.bookmark_fill : CupertinoIcons.clock,
                  size: 14,
                  color: v.manual ? const Color(0xFFFFC857) : mutedFg,
                ),
                const SizedBox(width: 10),
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
                        '${v.label.isNotEmpty ? '$stamp · ' : ''}$wc',
                        style: GoogleFonts.inter(
                          fontSize: 11.5,
                          color: mutedFg,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(color: divider, height: 1),
          Expanded(
            child: _decodeFailed || _ctrl == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        "This snapshot couldn't be decoded — restoring it "
                        "may produce unexpected results.",
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 12.5,
                          color: mutedFg,
                          height: 1.5,
                        ),
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    child: QuillEditor.basic(
                      controller: _ctrl!,
                      config: QuillEditorConfig(
                        showCursor: false,
                        autoFocus: false,
                        expands: true,
                        padding: EdgeInsets.zero,
                        customStyles: DefaultStyles(
                          paragraph: DefaultTextBlockStyle(
                            GoogleFonts.inter(
                              fontSize: 16,
                              height: 1.7,
                              color: fg.withValues(alpha: 0.9),
                            ),
                            const HorizontalSpacing(0, 0),
                            const VerticalSpacing(8, 0),
                            const VerticalSpacing(0, 0),
                            null,
                          ),
                          h1: DefaultTextBlockStyle(
                            GoogleFonts.inter(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                              color: fg,
                            ),
                            const HorizontalSpacing(0, 0),
                            const VerticalSpacing(18, 8),
                            const VerticalSpacing(0, 0),
                            null,
                          ),
                          h2: DefaultTextBlockStyle(
                            GoogleFonts.inter(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              height: 1.35,
                              color: fg,
                            ),
                            const HorizontalSpacing(0, 0),
                            const VerticalSpacing(14, 6),
                            const VerticalSpacing(0, 0),
                            null,
                          ),
                          h3: DefaultTextBlockStyle(
                            GoogleFonts.inter(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              height: 1.4,
                              color: fg,
                            ),
                            const HorizontalSpacing(0, 0),
                            const VerticalSpacing(12, 4),
                            const VerticalSpacing(0, 0),
                            null,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          Divider(color: divider, height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Restoring saves the current document as a new version '
                      'first, so this is reversible.',
                      style: GoogleFonts.inter(fontSize: 11.5, color: mutedFg),
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(
                      'Cancel',
                      style: GoogleFonts.inter(fontSize: 13, color: mutedFg),
                    ),
                  ),
                  const SizedBox(width: 4),
                  ElevatedButton(
                    onPressed: _decodeFailed
                        ? null
                        : () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A6CF7),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                    child: Text(
                      'Restore this version',
                      style: GoogleFonts.inter(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }

  String _formatStamp(DateTime t) {
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
