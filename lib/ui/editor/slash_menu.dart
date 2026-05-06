import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';

/// Possible block-level inserts triggered from the slash menu.
enum SlashAction {
  h1,
  h2,
  h3,
  body,
  bullet,
  numbered,
  checklist,
  quote,
  code,
  divider,
  image,
  generateNames,
}

class SlashItem {
  const SlashItem({
    required this.action,
    required this.label,
    required this.hint,
    required this.icon,
    required this.keywords,
  });

  final SlashAction action;
  final String label;
  final String hint;
  final IconData icon;
  final List<String> keywords;
}

const _items = <SlashItem>[
  SlashItem(
    action: SlashAction.h1,
    label: 'Heading 1',
    hint: 'Section title',
    icon: Icons.title,
    keywords: ['h1', 'heading', 'title'],
  ),
  SlashItem(
    action: SlashAction.h2,
    label: 'Heading 2',
    hint: 'Subsection',
    icon: Icons.title,
    keywords: ['h2', 'heading', 'subtitle'],
  ),
  SlashItem(
    action: SlashAction.h3,
    label: 'Heading 3',
    hint: 'Sub-subsection',
    icon: Icons.title,
    keywords: ['h3', 'heading'],
  ),
  SlashItem(
    action: SlashAction.body,
    label: 'Body text',
    hint: 'Plain paragraph',
    icon: Icons.notes,
    keywords: ['body', 'text', 'paragraph', 'p'],
  ),
  SlashItem(
    action: SlashAction.bullet,
    label: 'Bulleted list',
    hint: 'Unordered list',
    icon: Icons.format_list_bulleted,
    keywords: ['bullet', 'list', 'ul'],
  ),
  SlashItem(
    action: SlashAction.numbered,
    label: 'Numbered list',
    hint: 'Ordered list',
    icon: Icons.format_list_numbered,
    keywords: ['number', 'numbered', 'list', 'ol'],
  ),
  SlashItem(
    action: SlashAction.checklist,
    label: 'Checklist',
    hint: 'Todo items',
    icon: Icons.checklist,
    keywords: ['check', 'todo', 'task'],
  ),
  SlashItem(
    action: SlashAction.quote,
    label: 'Quote',
    hint: 'Blockquote',
    icon: Icons.format_quote,
    keywords: ['quote', 'blockquote'],
  ),
  SlashItem(
    action: SlashAction.code,
    label: 'Code block',
    hint: 'Monospace block',
    icon: Icons.code,
    keywords: ['code', 'block', 'mono'],
  ),
  SlashItem(
    action: SlashAction.divider,
    label: 'Divider',
    hint: 'Horizontal rule',
    icon: Icons.horizontal_rule,
    keywords: ['divider', 'hr', 'line', 'rule'],
  ),
  SlashItem(
    action: SlashAction.image,
    label: 'Image',
    hint: 'Insert from gallery',
    icon: Icons.image,
    keywords: ['image', 'photo', 'picture'],
  ),
  SlashItem(
    action: SlashAction.generateNames,
    label: 'Generate names',
    hint: 'AI character namer (gender, origin, era, alliteration)',
    icon: Icons.face_retouching_natural,
    keywords: ['name', 'character', 'generate', 'ai'],
  ),
];

/// Detects `/` typed at the start of an empty line and surfaces a popup
/// menu of block inserts. Filters as the user keeps typing; on selection,
/// removes the `/<query>` text and applies the chosen insert.
class SlashMenuController {
  SlashMenuController({
    required this.controller,
    required this.context,
    required this.onAction,
  }) {
    controller.addListener(_onChange);
  }

  final QuillController controller;
  final BuildContext context;
  final void Function(SlashAction action) onAction;

  OverlayEntry? _entry;
  int? _slashOffset;
  String _query = '';
  int _highlight = 0;
  String _lastText = '';

  void dispose() {
    controller.removeListener(_onChange);
    _close();
  }

  void _onChange() {
    final doc = controller.document;
    final text = doc.toPlainText();
    final sel = controller.selection;
    if (!sel.isValid) {
      if (_entry != null) _close();
      _lastText = text;
      return;
    }
    final caret = sel.baseOffset;

    if (_entry == null) {
      // Detect a fresh `/` typed at the start of a line.
      final inserted = text.length > _lastText.length;
      if (inserted &&
          caret > 0 &&
          caret <= text.length &&
          text[caret - 1] == '/' &&
          _atLineStart(text, caret - 1)) {
        _slashOffset = caret - 1;
        _query = '';
        _highlight = 0;
        _show();
      }
    } else {
      // Menu is open — keep the query in sync, or close if invalidated.
      final start = _slashOffset!;
      if (caret < start || start >= text.length || text[start] != '/') {
        _close();
      } else {
        final end = caret.clamp(start + 1, text.length);
        final q = text.substring(start + 1, end);
        if (q.contains('\n') || q.contains(' ')) {
          _close();
        } else {
          _query = q;
          _highlight = 0;
          _entry?.markNeedsBuild();
        }
      }
    }
    _lastText = text;
  }

  bool _atLineStart(String text, int idx) {
    if (idx == 0) return true;
    final prev = text[idx - 1];
    return prev == '\n';
  }

  List<SlashItem> _filtered() {
    final q = _query.toLowerCase().trim();
    if (q.isEmpty) return _items;
    return _items
        .where((i) =>
            i.label.toLowerCase().contains(q) ||
            i.keywords.any((k) => k.startsWith(q)))
        .toList();
  }

  void _show() {
    final overlay = Overlay.of(context);
    _entry = OverlayEntry(builder: (ctx) => _build(ctx));
    overlay.insert(_entry!);
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    _slashOffset = null;
    _query = '';
    _highlight = 0;
  }

  void _commit(SlashItem item) {
    final start = _slashOffset;
    final caret = controller.selection.baseOffset;
    _close();
    if (start == null) return;
    final length = (caret - start).clamp(0, controller.document.length - start);
    if (length > 0) {
      controller.replaceText(
        start,
        length,
        '',
        TextSelection.collapsed(offset: start),
      );
    }
    onAction(item.action);
  }

  bool handleKey(KeyEvent event) {
    if (_entry == null) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    final filtered = _filtered();
    if (filtered.isEmpty) return false;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _highlight = (_highlight + 1) % filtered.length;
      _entry?.markNeedsBuild();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _highlight = (_highlight - 1 + filtered.length) % filtered.length;
      _entry?.markNeedsBuild();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      _commit(filtered[_highlight.clamp(0, filtered.length - 1)]);
      return true;
    }
    return false;
  }

  Widget _build(BuildContext ctx) {
    final brightness = MediaQuery.platformBrightnessOf(ctx);
    final isDark = brightness == Brightness.dark;
    final filtered = _filtered();

    if (filtered.isEmpty) {
      return const SizedBox.shrink();
    }

    final bg = isDark ? const Color(0xFF1F2126) : Colors.white;
    final fg = isDark ? Colors.white : const Color(0xFF1A1A1F);
    final muted = fg.withValues(alpha: 0.55);
    final accentBg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFFEFF3FE);
    final border = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);

    final size = MediaQuery.sizeOf(ctx);
    final width = size.width.clamp(0.0, 320.0);
    final left = (size.width - width) / 2;
    final top = size.height * 0.28;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: width,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                        alpha: isDark ? 0.55 : 0.18),
                    blurRadius: 30,
                    spreadRadius: -8,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.command, size: 11, color: muted),
                        const SizedBox(width: 6),
                        Text(
                          _query.isEmpty
                              ? 'Insert block'
                              : 'Filter: $_query',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: muted,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          for (var i = 0; i < filtered.length; i++)
                            _row(filtered[i], i == _highlight,
                                fg, muted, accentBg),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(SlashItem item, bool active, Color fg, Color muted,
      Color activeBg) {
    return InkWell(
      onTap: () => _commit(item),
      child: Container(
        color: active ? activeBg : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(item.icon, size: 16, color: fg.withValues(alpha: 0.75)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.label,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                  Text(
                    item.hint,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: muted,
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
}
