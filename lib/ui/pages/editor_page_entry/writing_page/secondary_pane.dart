import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';

/// Read-only secondary pane for split-screen reference reading.
/// Shows the rendered Quill content of a *different* section so the
/// writer can keep, say, chapter 2 visible while editing chapter 5.
///
/// We intentionally don't make this a second editor: the editor state
/// machine assumes one active section per provider, and the spec calls
/// for "independent section selection over the same binder" — read-only
/// satisfies that without rewriting the controller layer.
class SecondaryPane extends StatefulWidget {
  const SecondaryPane({
    super.key,
    required this.onClose,
    this.width = 360,
    this.onWidthChanged,
    this.minWidth = 240,
    this.maxWidth = 900,
  });

  final VoidCallback onClose;
  // Initial width on mount. Resize state lives inside the widget so a
  // drag doesn't `setState` the whole editor tree — only this pane
  // rebuilds. [onWidthChanged] is a "settled" callback fired on drag
  // end so the parent can persist the chosen width.
  final double width;
  final ValueChanged<double>? onWidthChanged;
  final double minWidth;
  final double maxWidth;

  @override
  State<SecondaryPane> createState() => _SecondaryPaneState();
}

class _SecondaryPaneState extends State<SecondaryPane> {
  String? _sectionId;
  late double _width;

  @override
  void initState() {
    super.initState();
    _width = widget.width.clamp(widget.minWidth, widget.maxWidth);
  }

  @override
  void didUpdateWidget(covariant SecondaryPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Adopt a parent-provided width change only if the parent moved it
    // intentionally (different from the last value we reported). Avoids
    // the parent's persistence callback echoing back and stomping the
    // user's in-progress drag.
    if (widget.width != oldWidget.width && widget.width != _width) {
      _width = widget.width.clamp(widget.minWidth, widget.maxWidth);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = theme.textTheme.bodyMedium?.color ?? Colors.black;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    return Consumer<EditorProvider>(
      builder: (context, provider, _) {
        final book = provider.activeBook;
        if (book == null) return const SizedBox.shrink();
        final candidates = book.sections
            .where((s) =>
                s.kind != SectionKind.folder &&
                s.kind != SectionKind.research &&
                s.kind != SectionKind.trash &&
                s.kind != SectionKind.act)
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
        SectionModel? section;
        for (final s in candidates) {
          if (s.id == _sectionId) {
            section = s;
            break;
          }
        }
        section ??= candidates.firstWhere(
          (s) => s.id != provider.activeSection?.id,
          orElse: () => candidates.isEmpty
              ? SectionModel(
                  id: 'empty',
                  title: 'No sections',
                  content: '',
                  sectionColor: Colors.grey,
                )
              : candidates.first,
        );

        return SizedBox(
          width: _width,
          child: Row(
            children: [
              _ResizeHandle(
                isDark: isDark,
                onDrag: (delta) {
                  // Dragging the handle LEFT (negative dx) widens the
                  // pane — the pane is anchored to the right edge of
                  // the editor, so left motion grows it.
                  setState(() {
                    _width = (_width - delta)
                        .clamp(widget.minWidth, widget.maxWidth);
                  });
                },
                onDragEnd: () => widget.onWidthChanged?.call(_width),
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border:
                        Border(left: BorderSide(color: borderColor)),
                  ),
                  child: Column(
                    children: [
                      _header(context, provider, candidates, section,
                          textColor, isDark),
                      const Divider(height: 1),
                      Expanded(child: _body(section, isDark, textColor)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(
    BuildContext context,
    EditorProvider provider,
    List<SectionModel> candidates,
    SectionModel section,
    Color textColor,
    bool isDark,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      child: Row(
        children: [
          Icon(CupertinoIcons.book,
              size: 14, color: textColor.withValues(alpha: 0.55)),
          const SizedBox(width: 6),
          Expanded(
            child: PopupMenuButton<String>(
              tooltip: 'Pick section',
              initialValue: section.id,
              onSelected: (id) => setState(() => _sectionId = id),
              itemBuilder: (_) => [
                for (final s in candidates)
                  PopupMenuItem(
                    value: s.id,
                    child: Text(s.title.isEmpty ? 'Untitled' : s.title,
                        style: GoogleFonts.inter(fontSize: 12)),
                  ),
              ],
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      section.title.isEmpty ? 'Untitled' : section.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: textColor.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(CupertinoIcons.chevron_down,
                      size: 10, color: textColor.withValues(alpha: 0.5)),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close split view',
            icon: Icon(CupertinoIcons.xmark,
                size: 14, color: textColor.withValues(alpha: 0.55)),
            visualDensity: VisualDensity.compact,
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _body(SectionModel section, bool isDark, Color textColor) {
    if (section.content.trim().isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'This section is empty.',
            style: GoogleFonts.inter(
              fontSize: 12,
              color: textColor.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }
    try {
      final ops = jsonDecode(section.content);
      if (ops is! List) return _plain(section, textColor);
      final document = Document.fromJson(ops);
      final controller = QuillController(
        document: document,
        readOnly: true,
        selection: const TextSelection.collapsed(offset: 0),
      );
      return Padding(
        padding: const EdgeInsets.all(12),
        child: QuillEditor.basic(
          controller: controller,
          config: const QuillEditorConfig(
            padding: EdgeInsets.zero,
            scrollable: true,
            autoFocus: false,
            expands: true,
          ),
        ),
      );
    } catch (_) {
      return _plain(section, textColor);
    }
  }

  Widget _plain(SectionModel section, Color textColor) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Text(
        section.content,
        style: GoogleFonts.inter(
          fontSize: 13,
          color: textColor.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}

/// Vertical drag handle on the pane's left edge. The hit area is wider
/// than the visual line so users don't have to pixel-hunt; the line
/// itself only brightens on hover/drag so it doesn't dominate the chrome.
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({
    required this.isDark,
    required this.onDrag,
    this.onDragEnd,
  });

  final bool isDark;
  final ValueChanged<double> onDrag;
  final VoidCallback? onDragEnd;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hover = false;
  bool _dragging = false;

  void _endDrag() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onDragEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final highlight = _hover || _dragging;
    final lineColor = highlight
        ? Colors.blueAccent.withValues(alpha: 0.7)
        : (widget.isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.06));
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragEnd: (_) => _endDrag(),
        onHorizontalDragCancel: _endDrag,
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        child: SizedBox(
          width: 8,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: highlight ? 2 : 1,
              color: lineColor,
            ),
          ),
        ),
      ),
    );
  }
}
